#!/usr/bin/env bash
#
# mayhem/build.sh — build the pdb crate's cargo-fuzz target as a sanitized libFuzzer
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the crate's own
# test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# This FIRST build (online) populates the cargo registry under $CARGO_HOME; the
# re-run resolves crates from that cache (the runtime exports CARGO_NET_OFFLINE=true).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
: "${SRC:=/mayhem}"

cd "$SRC"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build (ASan is Rust-side via
# -Zsanitizer=address, NOT clang's $SANITIZER_FLAGS — rustc ignores clang flags). --cfg fuzzing
# matches libfuzzer-sys; force-frame-pointers aids ASan backtraces. $RUST_DEBUG_FLAGS threads the
# rlenv debug-info policy; -Zdwarf-version=3 pins DWARF < 4 (§6.2 item 10 — LLVM 19 defaults to 5).
#
# PANIC-SITE ATTRIBUTION (why -Cpanic=abort + panic_immediate_abort below).
# Mayhem buckets a run's crashes into defects by the TOP of the backtrace. A plain Rust
# panic aborts a long way from the code that panicked — core::panicking::panic_fmt ->
# rust_begin_unwind -> panic_with_hook -> libfuzzer-sys' hook -> std::process::abort ->
# abort -> raise — so the first ~16 frames are identical for EVERY panic, whatever the
# bug. This target's three distinct bugs (pdbi.rs:140 slice index, tpi/data.rs:485
# unreachable!(), tpi/mod.rs:475 add-overflow) only diverge at frame #16, and Mayhem
# folded all 13 replayed crashers into ONE defect (runs 1, 3, 4 and 5 of
# pdb-parse-buggy-mhh-run-11 all reported n_defects=1) where the original 2026-04
# mayhemheroes run — built by an older cargo-fuzz whose stacks were shorter — reported 4.
# Building std with `panic_immediate_abort` makes a panic abort AT the panic site: the
# crash IP is now the faulting pdb function (frames #4–#6), so each bug keeps its own
# signature. The trade is the pretty-printed "thread panicked at …" line; the location
# is still in DWARF and in the (unchanged) source.
#   -Cpanic=abort                  required by panic_immediate_abort
#   -Zbuild-std=std,panic_abort    without panic_abort: E0152 (two panic runtimes linked)
#   -Zmerge-functions=disabled     keeps LLVM from folding the cold panic helpers into one
#                                  mislabelled symbol (slice_index_fail read as
#                                  copy_from_slice::len_mismatch_fail)
#   --strip-dead-code              drops cargo-fuzz's -Clink-dead-code, which under
#                                  -Zbuild-std makes compiler_builtins fail to compile
#                                  ("cannot call functions through upstream monomorphizations")
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebuginfo=2 -Zdwarf-version=3 -Cforce-frame-pointers -Cpanic=abort -Zmerge-functions=disabled"
BUILD_STD_FLAGS=(--strip-dead-code -Z build-std=std,panic_abort -Z build-std-features=panic_immediate_abort)

# Additive mayhem/fuzz crate (ported from the fork's original fuzz/ harness; upstream ships none).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions \
    "${BUILD_STD_FLAGS[@]}" --target-dir "$SRC/$FUZZ_DIR/target" "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"

  # Non-instrumented (no sanitizer) twin of the same harness — the mayhemheroes
  # project's live Mayhemfile ran one alongside the ASan binary (`<t>_no_inst`,
  # `libfuzzer: false`, one file per invocation) for its own triage/exploitability
  # pass; port that second cmd here too so replays get the same triage inputs. Same
  # panic-site attribution flags, so both cmds report a crash the same way.
  NO_INST_RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing -Cdebuginfo=2 -Zdwarf-version=3 -Cforce-frame-pointers -Cpanic=abort -Zmerge-functions=disabled"
  RUSTFLAGS="$NO_INST_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" --sanitizer none -O --debug-assertions \
    "${BUILD_STD_FLAGS[@]}" --target-dir "$SRC/$FUZZ_DIR/target-no-inst" "$t"
  no_inst_bin="$SRC/$FUZZ_DIR/target-no-inst/$TRIPLE/release/$t"
  [ -x "$no_inst_bin" ] || { echo "ERROR: expected fuzz binary not found at $no_inst_bin" >&2; exit 1; }
  cp "$no_inst_bin" "/mayhem/${t}_no_inst"
  echo "built /mayhem/${t}_no_inst (no sanitizer)"
done

# Build the crate's OWN test suite with the project's NORMAL flags (no sanitizer) so
# mayhem/test.sh only RUNS it. Same env test.sh uses (RUSTFLAGS cleared) so the
# fingerprints match and test.sh never recompiles.
echo "=== cargo test --no-run (pdb test suite, normal flags) ==="
RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS"

echo "build.sh complete"

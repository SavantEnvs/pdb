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
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebuginfo=2 -Zdwarf-version=3 -Cforce-frame-pointers"

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
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the crate's OWN test suite with the project's NORMAL flags (no sanitizer) so
# mayhem/test.sh only RUNS it. Same env test.sh uses (RUSTFLAGS cleared) so the
# fingerprints match and test.sh never recompiles.
echo "=== cargo test --no-run (pdb test suite, normal flags) ==="
RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS"

echo "build.sh complete"

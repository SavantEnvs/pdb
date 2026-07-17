#!/usr/bin/env bash
#
# pdb/mayhem/test.sh — RUN the pdb crate's own test suite (the FUZZED crate) and emit a CTRF
# summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: the fuzz target drives PDB::open() + pdb_information/type_information/
# id_information/debug_information over the MSVC PDB parser. Upstream ships real tests asserting
# parser behavior — the in-crate #[cfg(test)] unit tests plus the integration tests under tests/
# (pdb_information.rs, type_information.rs, symbol_table.rs, pdb_lines.rs, debug_information.rs,
# id_information.rs, omap_address_translation.rs, modi_symbol_depth.rs) which parse the committed
# fixtures/ PDBs and assert VALUE-EXACT results (GUIDs, ages, stream names, type counts, symbol
# names, line numbers, OMAP translations). A no-op / "return Ok" patch to the parser CANNOT pass
# these asserts. This script only RUNS the suite via `cargo test`; build.sh already compiled it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (pdb parser suite: unit + integration tests) ==="
# Image DEFAULT toolchain. --no-fail-fast so we count every test; RUSTFLAGS cleared to match
# the normal-flags test build from build.sh (no recompilation, no sanitizer).
out="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"

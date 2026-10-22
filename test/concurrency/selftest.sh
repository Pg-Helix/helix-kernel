#!/bin/sh
# Proves this harness actually detects failure, instead of trusting it
# on faith. Copies the real scenario files into a scratch directory,
# injects one break at a time, and asserts each injected break makes
# cc_run_scenario return nonzero. Restores nothing in place -- the
# scratch copies are thrown away; the committed scenario files are never
# touched or left broken.
set -eu
REAL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC_SCRIPT_DIR=$REAL_DIR
export CC_SCRIPT_DIR
. "$REAL_DIR/lib.sh"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp "$REAL_DIR"/*.sql "$SCRATCH/"
# From here on, cc_run_scenario (via $CC_SCRIPT_DIR) resolves files
# against the scratch copy, which carries both the untouched originals
# and the broken variants created below.
CC_SCRIPT_DIR=$SCRATCH

RUN_ID=$$
fail=0

assert_fails() {
    label=$1 db_suffix=$2 setup=$3 a=$4 b=$5 check=$6
    if cc_run_scenario "$label" "helix_cc_selftest_${RUN_ID}_${db_suffix}" "$setup" "$a" "$b" "$check" >/tmp/selftest_out.log 2>&1; then
        echo "SELFTEST FAIL: '$label' was expected to fail but the harness reported ok"
        cat /tmp/selftest_out.log
        fail=1
    else
        echo "selftest ok: '$label' correctly detected as a failure"
    fi
}

# 1. Broken include path: setup can never find _install.sql.
sed 's/_install\.sql/_does_not_exist.sql/' "$SCRATCH/setup_competing_claim.sql" > "$SCRATCH/setup_broken_include.sql"
assert_fails "broken include path" 1 setup_broken_include.sql session_claim_a.sql session_claim_b.sql check_competing_claim.sql

# 2. Injected SQL error in setup (a bogus statement after the real
# setup): must abort setup under ON_ERROR_STOP=1, not be swallowed.
cp "$SCRATCH/setup_competing_claim.sql" "$SCRATCH/setup_sql_error.sql"
printf '\nSELECT this_function_does_not_exist();\n' >> "$SCRATCH/setup_sql_error.sql"
assert_fails "injected SQL error in setup" 2 setup_sql_error.sql session_claim_a.sql session_claim_b.sql check_competing_claim.sql

# 3. Remove the expected row: session A does nothing (no claim_job call
# at all), so the check's "exactly 1 job, attempts=1" assertion must fail
# instead of a zero/placeholder result passing silently.
printf 'SELECT pg_advisory_lock_shared(:gate_key);\nSELECT pg_advisory_unlock_shared(:gate_key);\nSELECT 1;\n' > "$SCRATCH/session_noop.sql"
assert_fails "missing expected row (session never claims)" 3 setup_competing_claim.sql session_noop.sql session_claim_b.sql check_competing_claim.sql

# 4. Force a wrong outcome: a check script that demands an impossible
# value must fail even though the real race behaved correctly.
sed "s/v_attempts IS DISTINCT FROM 1/v_attempts IS DISTINCT FROM 999/" "$SCRATCH/check_competing_claim.sql" > "$SCRATCH/check_wrong_outcome.sql"
assert_fails "forced wrong outcome" 4 setup_competing_claim.sql session_claim_a.sql session_claim_b.sql check_wrong_outcome.sql

exit $fail

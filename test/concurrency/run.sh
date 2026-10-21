#!/bin/sh
# Real concurrent-session tests (not serial simulation): two actual psql
# client processes launched together against the same running cluster.
# Requires the extension already built/installed and a cluster already
# running (ci/run-tests.sh does both before calling this; PGHOST/PGDATABASE
# must point at it). Separate from pg_regress's REGRESS suite because
# pg_regress runs everything through one serial client connection and
# cannot express "two sessions act at the same time."
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PGDATABASE=helix_concurrency_check
dropdb --if-exists "$PGDATABASE"
createdb "$PGDATABASE"
PSQL="psql -X -q -v ON_ERROR_STOP=0"

fail=0

run_scenario() {
    name=$1
    setup=$2
    a=$3
    b=$4
    check=$5

    $PSQL -f "$SCRIPT_DIR/$setup" >/tmp/concurrency_setup.out 2>&1

    $PSQL -f "$SCRIPT_DIR/$a" >/tmp/concurrency_a.out 2>&1 &
    pid_a=$!
    $PSQL -f "$SCRIPT_DIR/$b" >/tmp/concurrency_b.out 2>&1 &
    pid_b=$!
    wait "$pid_a"
    wait "$pid_b"

    if $PSQL -f "$SCRIPT_DIR/$check" >/tmp/concurrency_check.out 2>&1; then
        if grep -q FAIL /tmp/concurrency_check.out; then
            echo "FAIL: $name"
            cat /tmp/concurrency_a.out /tmp/concurrency_b.out /tmp/concurrency_check.out
            fail=1
        else
            echo "ok: $name"
        fi
    else
        echo "FAIL: $name (check script errored)"
        cat /tmp/concurrency_check.out
        fail=1
    fi
}

run_scenario "competing claim_job: exactly one session claims the job" \
    setup_competing_claim.sql session_claim_a.sql session_claim_b.sql check_competing_claim.sql

run_scenario "competing publish_result: exactly one session's CAS succeeds" \
    setup_competing_publish.sql session_publish_a.sql session_publish_b.sql check_competing_publish.sql

exit $fail

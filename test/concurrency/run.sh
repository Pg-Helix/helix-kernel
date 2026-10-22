#!/bin/sh
# Real concurrent-session tests (not serial simulation): two actual psql
# client processes launched together against the same running cluster,
# synchronized by a deterministic advisory-lock starting gate (lib.sh),
# not by hoping two pg_sleep calls overlap. Requires the extension
# already built/installed and a cluster already running (ci/run-tests.sh
# does both before calling this; PGHOST must point at it). Separate from
# pg_regress's REGRESS suite because pg_regress runs everything through
# one serial client connection and cannot express "two sessions act at
# the same time."
#
# Each scenario owns a uniquely-named, freshly-created database, dropped
# on success, failure or interruption -- never a fixed shared name, never
# a pre-existing developer database.
set -eu
CC_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CC_SCRIPT_DIR
. "$CC_SCRIPT_DIR/lib.sh"

RUN_ID=$$
fail=0

cc_run_scenario \
    "competing claim_job: exactly one session claims the job" \
    "helix_cc_claim_$RUN_ID" \
    setup_competing_claim.sql session_claim_a.sql session_claim_b.sql check_competing_claim.sql \
    || fail=1

cc_run_scenario \
    "competing publish_result: exactly one session's CAS succeeds" \
    "helix_cc_publish_$RUN_ID" \
    setup_competing_publish.sql session_publish_a.sql session_publish_b.sql check_competing_publish.sql \
    || fail=1

exit $fail

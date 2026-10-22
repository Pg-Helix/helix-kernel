#!/bin/sh
# Shared shell helpers for the real two-session concurrency scenarios in
# this directory. Sourced by run.sh and selftest.sh.
set -eu

PSQL="psql -X -q -v ON_ERROR_STOP=1"

# cc_gate_open/cc_gate_release_when_both_waiting: a deterministic
# "starting gate" so two racer sessions provably overlap instead of
# hoping two pg_sleep calls happen to line up. A dedicated holder
# connection takes an EXCLUSIVE advisory lock on a key unique to THIS
# scenario invocation; each racer blocks trying to take the SAME key in
# SHARED mode (shared-vs-shared never conflicts, so once the holder
# releases, both racers become grantable together, not one-then-the-
# other). Before releasing, the gate polls pg_locks and requires seeing
# BOTH racers already queued as waiters -- proving genuine concurrent
# arrival, not an accident of whichever connection happened to start first.
#
# The key is generated fresh per cc_run_scenario call (process PID plus a
# per-process counter), not a fixed constant: selftest.sh runs several
# scenarios back to back on the same cluster within one process, and a
# fixed key risked a just-finished scenario's session not having fully
# released by the time the next one's gate-holder tried to acquire it --
# the exact intermittent "never saw two waiters" failure this fixes.
CC_GATE_COUNTER=0
cc_next_gate_key() {
    CC_GATE_COUNTER=$((CC_GATE_COUNTER + 1))
    echo $(((($$ % 100000) * 1000) + CC_GATE_COUNTER))
}

cc_gate_open() {
    # $1 = fifo path, $2 = gate key
    fifo=$1
    key=$2
    rm -f "$fifo"
    mkfifo "$fifo"
    ( exec $PSQL > /tmp/concurrency_gate.out 2>&1 < "$fifo" ) &
    echo $! > "$fifo.pid"
    exec 8>"$fifo"
    echo "SELECT pg_advisory_lock($key);" >&8
}

# Blocks (polling, bounded) until pg_locks shows two distinct sessions
# waiting on the gate key, then opens it. Fails loudly if that never
# happens -- a racer that never even reached the gate is a setup bug,
# not a race outcome.
cc_gate_release_when_both_waiting() {
    key=$1
    i=0
    while true; do
        waiters=$($PSQL -tAc "
            SELECT count(*) FROM pg_locks
            WHERE locktype = 'advisory' AND NOT granted
              AND ((classid::bigint << 32) | objid::bigint) = $key::bigint
        " 2>/dev/null || echo 0)
        if [ "${waiters:-0}" -ge 2 ]; then
            break
        fi
        i=$((i + 1))
        if [ "$i" -gt 400 ]; then
            echo "gate: never saw two waiters on advisory lock $key (saw $waiters)" >&2
            return 1
        fi
        sleep 0.05
    done
    echo "SELECT pg_advisory_unlock($key);" >&8
    echo "\\q" >&8
    exec 8>&-
}

# cc_run_scenario NAME DB SETUP A B CHECK
# Every step uses ON_ERROR_STOP=1: an unexpected error now fails the
# scenario instead of being swallowed. Owns its own uniquely-named
# database (caller picks DB) and its own uniquely-generated gate key,
# created/dropped here -- never a fixed shared name or key, never a
# pre-existing developer database.
cc_run_scenario() {
    name=$1 db=$2 setup=$3 a=$4 b=$5 check=$6
    dir=$CC_SCRIPT_DIR
    gate_key=$(cc_next_gate_key)

    export PGDATABASE="$db"
    dropdb --if-exists --force "$db"
    createdb "$db"

    if ! $PSQL -f "$dir/$setup" > /tmp/concurrency_setup.out 2>&1; then
        echo "FAIL: $name (setup)"
        cat /tmp/concurrency_setup.out
        dropdb --if-exists --force "$db"
        return 1
    fi

    fifo="/tmp/concurrency_gate_$$_$gate_key"
    cc_gate_open "$fifo" "$gate_key"

    $PSQL -v gate_key="$gate_key" -f "$dir/$a" > /tmp/concurrency_a.out 2>&1 &
    pid_a=$!
    $PSQL -v gate_key="$gate_key" -f "$dir/$b" > /tmp/concurrency_b.out 2>&1 &
    pid_b=$!

    if ! cc_gate_release_when_both_waiting "$gate_key"; then
        kill "$pid_a" "$pid_b" 2>/dev/null || true
        wait "$pid_a" 2>/dev/null || true
        wait "$pid_b" 2>/dev/null || true
        cat /tmp/concurrency_gate.out
        echo "FAIL: $name (sessions never both reached the gate)"
        rm -f "$fifo" "$fifo.pid"
        dropdb --if-exists --force "$db"
        return 1
    fi

    a_status=0; b_status=0
    wait "$pid_a" || a_status=$?
    wait "$pid_b" || b_status=$?
    rm -f "$fifo" "$fifo.pid"

    if [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
        echo "FAIL: $name (a session errored unexpectedly: a=$a_status b=$b_status)"
        cat /tmp/concurrency_a.out /tmp/concurrency_b.out
        dropdb --if-exists --force "$db"
        return 1
    fi

    if $PSQL -f "$dir/$check" > /tmp/concurrency_check.out 2>&1; then
        echo "ok: $name"
        dropdb --if-exists --force "$db"
        return 0
    else
        echo "FAIL: $name (check)"
        cat /tmp/concurrency_a.out /tmp/concurrency_b.out /tmp/concurrency_check.out
        dropdb --if-exists --force "$db"
        return 1
    fi
}

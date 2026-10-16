#!/bin/sh
# Build and test the extension inside an official postgres:<major> image.
# Usage: docker run --rm -v "$PWD":/src:ro postgres:17 /src/ci/run-tests.sh
set -eu
apt-get update -qq
apt-get install -y -qq build-essential postgresql-server-dev-"$PG_MAJOR" >/dev/null
mkdir /build && cp -r /src/. /build/ && chown -R postgres /build
cd /build && make clean >/dev/null && make && make install
su postgres -c "initdb -D /tmp/pg >/dev/null && pg_ctl -D /tmp/pg -w -o '-k /tmp -c listen_addresses=' start >/dev/null"
su postgres -c "cd /build && PGHOST=/tmp make installcheck" || { cat /build/regression.diffs 2>/dev/null; exit 1; }

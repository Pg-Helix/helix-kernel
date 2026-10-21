EXTENSION    = helix
DATA         = sql/helix--0.1.0.sql
MODULE_big   = helix
OBJS         = src/ai/version.o
REGRESS_OPTS = --inputdir=test/regress
REGRESS      = setup register_basic register_composite_key register_rejects_keyless register_requires_trigger_privilege tenant_isolation status_view identifier_injection \
               k3_capture_and_claim k3_publish_result_cas k3_tombstone k3_lease_expiry k3_worker_role_boundary \
               k3_generation_fence k3_dead_letter k3_claim_model_scope k3_get_job_input \
               teardown
PG_CPPFLAGS  = -I$(CURDIR)/include

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Real two-session concurrency tests (test/concurrency/): pg_regress runs
# everything through one serial client, so it cannot express "two sessions
# act at the same time." Needs the extension already `make install`ed and
# a cluster already running and reachable via psql's usual PG* env vars.
.PHONY: concurrency-check
concurrency-check:
	sh test/concurrency/run.sh

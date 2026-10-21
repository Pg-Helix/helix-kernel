EXTENSION    = helix
DATA         = sql/helix--0.1.0.sql
MODULE_big   = helix
OBJS         = src/ai/version.o
REGRESS_OPTS = --inputdir=test/regress
REGRESS      = setup register_basic register_composite_key register_rejects_keyless tenant_isolation status_view identifier_injection \
               k3_capture_and_claim k3_publish_result_cas k3_tombstone k3_lease_expiry k3_worker_role_boundary \
               teardown
PG_CPPFLAGS  = -I$(CURDIR)/include

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

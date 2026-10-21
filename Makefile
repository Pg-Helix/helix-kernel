EXTENSION    = helix
DATA         = sql/helix--0.1.0.sql
MODULE_big   = helix
OBJS         = src/ai/version.o
REGRESS_OPTS = --inputdir=test/regress
REGRESS      = setup register_basic register_composite_key register_rejects_keyless tenant_isolation status_view identifier_injection teardown
PG_CPPFLAGS  = -I$(CURDIR)/include

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

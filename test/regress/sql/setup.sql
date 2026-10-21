CREATE EXTENSION helix;

-- Ownership hardening (ADR-0006 decision 1, helix-atlas). CREATE EXTENSION
-- must run as a privileged installer, but nothing requires that installer
-- to keep ownership afterward -- and nothing should: FORCE ROW LEVEL
-- SECURITY on helix_ai.source/derived_value is a no-op for a superuser
-- owner (superusers bypass RLS unconditionally, FORCE notwithstanding), so
-- every SECURITY DEFINER function in this extension was running with RLS
-- silently disabled until ownership moves to a NOSUPERUSER NOBYPASSRLS
-- role. Real deployments must run the same reassignment after install;
-- extend this list as new helix_ai objects are added.
CREATE ROLE helix_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE helix_worker NOLOGIN;

ALTER SCHEMA helix_ai OWNER TO helix_owner;
ALTER TABLE helix_ai.source OWNER TO helix_owner;
ALTER TABLE helix_ai.derived_value OWNER TO helix_owner;
ALTER TYPE helix_ai.pseudo_column_status OWNER TO helix_owner;
ALTER VIEW helix_ai.status OWNER TO helix_owner;
ALTER FUNCTION helix_ai.version() OWNER TO helix_owner;
ALTER FUNCTION helix_ai._source_key_expr(name[], name) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._create_enriched_view(bigint) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) OWNER TO helix_owner;
ALTER TABLE helix_ai.job OWNER TO helix_owner;
ALTER TYPE helix_ai.publish_outcome OWNER TO helix_owner;
ALTER FUNCTION helix_ai._row_key_jsonb(name[], record) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._tombstone_key(bigint, text, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai._capture_change() OWNER TO helix_owner;
ALTER FUNCTION helix_ai._ensure_capture_trigger(name, name) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.request_refresh(bigint, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.claim_job(text, integer, integer) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) OWNER TO helix_owner;
ALTER FUNCTION helix_ai.get_job_input(uuid, integer) OWNER TO helix_owner;

-- helix_worker (ADR-0006 decision 1) is the only role a real deployment
-- grants these three to; USAGE on the schema is required just to resolve
-- the function names, same as any other role calling into helix_ai.
GRANT USAGE ON SCHEMA helix_ai TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.claim_job(text, integer, integer) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.get_job_input(uuid, integer) TO helix_worker;

-- helix_owner (now NOSUPERUSER) runs register_source's own DDL (CREATE
-- TRIGGER, CREATE VIEW) as itself, not as whoever called register_source --
-- that DDL needs helix_owner's own privilege on the target table/schema
-- regardless of the caller-side has_table_privilege check register_source
-- performs. A real deployment grants this per schema it manages; tests
-- grant it once via default privileges so every table any test file goes
-- on to create is covered automatically.
GRANT CREATE ON SCHEMA public TO helix_owner;
ALTER DEFAULT PRIVILEGES GRANT TRIGGER ON TABLES TO helix_owner;

SELECT helix_ai.version();
SELECT nspname FROM pg_namespace WHERE nspname = 'helix_ai';

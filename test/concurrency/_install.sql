-- Shared by every scenario's setup.sql: install the extension with the
-- same ownership hardening as test/regress/sql/setup.sql (ADR-0006).
-- Idempotent role creation since helix_owner/helix_worker are cluster-wide
-- and may already exist from an earlier pg_regress run in this cluster.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'helix_owner') THEN
        CREATE ROLE helix_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'helix_worker') THEN
        CREATE ROLE helix_worker NOLOGIN;
    END IF;
END $$;

CREATE EXTENSION helix;

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

GRANT CREATE ON SCHEMA public TO helix_owner;
ALTER DEFAULT PRIVILEGES GRANT SELECT, TRIGGER ON TABLES TO helix_owner;

GRANT USAGE ON SCHEMA helix_ai TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.claim_job(text, integer, integer) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.get_job_input(uuid, integer) TO helix_worker;

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION helix" to load this file. \quit

-- Created here (not via control-file `schema`) so the schema is an extension member
-- and DROP EXTENSION removes it.
CREATE SCHEMA helix_ai;

CREATE FUNCTION helix_ai.version()
RETURNS text
AS 'MODULE_PATHNAME', 'helix_version'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

REVOKE ALL ON FUNCTION helix_ai.version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION helix_ai.version() TO PUBLIC;

-- =============================================================================
-- K2: registration (RFC-0001 M2, RFC-0003 pseudo-column lifecycle)
--
-- No new roles are created here: a narrow worker role that can write only
-- AI sidecars arrives in K3, where something other than register_source
-- itself first needs to write to helix_ai.derived_value. Until then, every
-- function below executes as whichever role owns the extension (SECURITY
-- DEFINER, fixed search_path, EXECUTE open to PUBLIC like version()) so an
-- ordinary application role can call it without direct table grants.
-- =============================================================================

-- pending: enqueued/never produced a result yet.
-- ready: value reflects the current source row, model and pipeline.
-- stale: the source row changed since value was generated.
-- failed: a worker gave up (see RFC-0003 dead-letter / attempts cap).
-- deleted: tombstoned; publish_result (K3) must reject any later write here.
CREATE TYPE helix_ai.pseudo_column_status AS ENUM ('pending', 'ready', 'stale', 'failed', 'deleted');

-- One row per register_source call: which table, which row key, which model
-- and pipeline this registration's enriched view and sidecar values are for.
-- tenant is read from the session (see register_source), never trusted from
-- the caller as a separate argument, so a connection cannot register on
-- behalf of a tenant it has not been placed into.
CREATE TABLE helix_ai.source (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant           text NOT NULL,
    schema_name      name NOT NULL,
    table_name       name NOT NULL,
    -- Composite primary keys are supported: this is the source table's own
    -- PRIMARY KEY column list, in key order, auto-detected by register_source
    -- (never caller-supplied) so it can never drift from the real key.
    key_columns      name[] NOT NULL,
    model_id         text NOT NULL,
    model_revision   text NOT NULL,
    -- dims/metric only apply to embedding bindings; NULL for other kinds
    -- (classification, summary, typed prediction).
    dims             integer,
    metric           text,
    pipeline_version text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant, schema_name, table_name, model_id, pipeline_version)
);

ALTER TABLE helix_ai.source ENABLE ROW LEVEL SECURITY;
-- Forced so even the table owner (every helix_ai function runs SECURITY
-- DEFINER as that owner) only ever sees/writes its own tenant's rows; a
-- superuser connection in tests or operations still bypasses RLS, which is
-- PostgreSQL's own behaviour and out of scope for this policy to change.
ALTER TABLE helix_ai.source FORCE ROW LEVEL SECURITY;

CREATE POLICY source_tenant_isolation ON helix_ai.source
    USING (tenant = current_setting('helix.tenant', true))
    WITH CHECK (tenant = current_setting('helix.tenant', true));

-- The AI-derived sidecar (RFC-0003): one row per (source_id, source_key).
-- source_key is a jsonb object {column_name: column_value::text, ...} for
-- every column in helix_ai.source.key_columns, built the same way by every
-- reader and writer (see helix_ai._source_key_expr) -- this exact shape is
-- the contract K3's publish_result and C1's worker must also produce.
-- value/generated_at stay NULL until K3's publish_result (compare-and-set)
-- exists; K2 only establishes the schema, the enriched view and the status
-- view that read it.
CREATE TABLE helix_ai.derived_value (
    source_id     bigint NOT NULL REFERENCES helix_ai.source(id) ON DELETE CASCADE,
    tenant        text NOT NULL,
    source_key    jsonb NOT NULL,
    source_digest text,
    status        helix_ai.pseudo_column_status NOT NULL DEFAULT 'pending',
    value         jsonb,
    generated_at  timestamptz,
    PRIMARY KEY (source_id, source_key)
);

ALTER TABLE helix_ai.derived_value ENABLE ROW LEVEL SECURITY;
ALTER TABLE helix_ai.derived_value FORCE ROW LEVEL SECURITY;

CREATE POLICY derived_value_tenant_isolation ON helix_ai.derived_value
    USING (tenant = current_setting('helix.tenant', true))
    WITH CHECK (tenant = current_setting('helix.tenant', true));

-- helix_ai.status: pending|ready|stale|failed|deleted per registered row.
-- security_invoker so a querying role's own RLS/grants apply -- not this
-- view's owner's -- on both helix_ai.source and helix_ai.derived_value.
CREATE VIEW helix_ai.status WITH (security_invoker = true) AS
SELECT
    s.id AS source_id,
    s.tenant,
    s.schema_name,
    s.table_name,
    dv.source_key,
    dv.status,
    dv.generated_at
FROM helix_ai.source s
LEFT JOIN helix_ai.derived_value dv ON dv.source_id = s.id;

-- _source_key_expr builds the SQL text of the jsonb object expression that
-- both the enriched view's join predicate and (in K3) publish_result must
-- use to identify a row -- one place defines the encoding so the two can
-- never drift apart. alias is the table alias the generated expression
-- reads columns from (e.g. "src"). Every identifier is passed through
-- format('%I', ...): key_columns ultimately comes from a real PRIMARY KEY's
-- column names, but this function makes no assumption about that -- it is
-- not safe to build this from caller-supplied text.
CREATE FUNCTION helix_ai._source_key_expr(key_columns name[], alias name)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
    SELECT 'jsonb_build_object(' || string_agg(format('%L, (%I.%I)::text', col, alias, col), ', ') || ')'
    FROM unnest(key_columns) AS col;
$$;

-- _create_enriched_view builds <schema>.<table>_ai: every column of the
-- registered table, plus ai_value/ai_status/ai_generated_at from the one
-- sidecar row matching this registration's source_id and row key. A plain
-- SELECT against it only ever reads the stored sidecar value -- it does not
-- call a model or trigger processing (see RFC-0003; refresh is request_refresh,
-- added in K3). security_invoker so the view enforces the querying role's own
-- grants/RLS on both the base table and helix_ai.derived_value, not the
-- view owner's.
CREATE FUNCTION helix_ai._create_enriched_view(p_source_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_source helix_ai.source%ROWTYPE;
BEGIN
    SELECT * INTO v_source FROM helix_ai.source WHERE id = p_source_id;

    EXECUTE format(
        'CREATE VIEW %I.%I WITH (security_invoker = true) AS
         SELECT src.*, dv.value AS ai_value, dv.status AS ai_status, dv.generated_at AS ai_generated_at
         FROM %I.%I AS src
         LEFT JOIN helix_ai.derived_value dv
           ON dv.source_id = %L AND %s',
        v_source.schema_name, v_source.table_name || '_ai',
        v_source.schema_name, v_source.table_name,
        p_source_id,
        helix_ai._source_key_expr(v_source.key_columns, 'src') || ' = dv.source_key'
    );
END;
$$;

REVOKE ALL ON FUNCTION helix_ai._create_enriched_view(bigint) FROM PUBLIC;

-- register_source registers schema.table for AI-derived values and creates
-- its enriched view (schema.table_ai). tenant comes only from the session
-- (helix.tenant), never as an argument -- see the tenant-isolation note on
-- helix_ai.source above. The table's row key is auto-detected from its own
-- PRIMARY KEY (composite keys supported); a table with no primary key is
-- rejected rather than silently registered without a stable identity.
CREATE FUNCTION helix_ai.register_source(
    p_schema           name,
    p_table            name,
    p_model_id         text,
    p_model_revision   text,
    p_pipeline_version text,
    p_dims             integer DEFAULT NULL,
    p_metric           text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_tenant      text;
    v_relid       oid;
    v_key_columns name[];
    v_id          bigint;
BEGIN
    v_tenant := current_setting('helix.tenant', true);
    IF v_tenant IS NULL OR v_tenant = '' THEN
        RAISE EXCEPTION 'helix: helix.tenant is not set for this session; register_source needs a tenant context';
    END IF;

    SELECT c.oid INTO v_relid
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema AND c.relname = p_table AND c.relkind IN ('r', 'p');

    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'helix: relation %.% not found', p_schema, p_table;
    END IF;

    SELECT array_agg(a.attname ORDER BY k.ord) INTO v_key_columns
    FROM pg_catalog.pg_constraint con
    JOIN pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
    JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
    WHERE con.conrelid = v_relid AND con.contype = 'p';

    IF v_key_columns IS NULL OR array_length(v_key_columns, 1) = 0 THEN
        RAISE EXCEPTION 'helix: table %.% has no primary key; register_source requires a stable row key', p_schema, p_table;
    END IF;

    INSERT INTO helix_ai.source (tenant, schema_name, table_name, key_columns, model_id, model_revision, dims, metric, pipeline_version)
    VALUES (v_tenant, p_schema, p_table, v_key_columns, p_model_id, p_model_revision, p_dims, p_metric, p_pipeline_version)
    RETURNING id INTO v_id;

    PERFORM helix_ai._create_enriched_view(v_id);

    RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) TO PUBLIC;

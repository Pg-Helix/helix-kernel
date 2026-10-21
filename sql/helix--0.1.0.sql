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
    dv.source_digest,
    dv.value,
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
    -- The real caller's effective role, not current_user: inside a
    -- SECURITY DEFINER function current_user is already this function's
    -- owner for the whole call, so has_table_privilege(current_user, ...)
    -- below would check the owner's privilege, not the caller's. The
    -- `role` GUC is unaffected by that switch and reflects SET ROLE
    -- (empirically verified: current_setting('role') still returns the
    -- caller's role from inside this function); 'none' means no SET ROLE
    -- was used, so the caller's actual connection identity is session_user.
    v_caller      text;
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

    -- ADR-0006 decision 2 (helix-atlas): register_source stays
    -- PUBLIC-executable, but a caller may only ask it to create a trigger
    -- and enriched view on a table the caller could already create a
    -- trigger on themselves -- otherwise this SECURITY DEFINER function
    -- would let any role attach a trigger to, and create a derived view
    -- over, any table in the database regardless of ownership.
    v_caller := current_setting('role');
    IF v_caller = 'none' THEN
        v_caller := session_user::text;
    END IF;

    IF NOT pg_catalog.has_table_privilege(v_caller, v_relid, 'TRIGGER') THEN
        RAISE EXCEPTION 'helix: insufficient privilege on %.% to register it (TRIGGER privilege required)', p_schema, p_table;
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
    PERFORM helix_ai._ensure_capture_trigger(p_schema, p_table);

    RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION helix_ai.register_source(name, name, text, text, text, integer, text) TO PUBLIC;

-- =============================================================================
-- K3: refresh/publish (RFC-0001 M3, RFC-0003 job/worker protocol, ADR-0003)
--
-- Native capture mode only (ADR-0003): a row trigger writes the outbox job
-- in the same transaction as the source change. External-Go polling mode
-- (for deployments that cannot grant trigger-create privilege) is documented
-- in ADR-0003/ADR-0004 as a weaker fallback and is not implemented here.
--
-- Credential boundary: claim_job and publish_result are REVOKEd from PUBLIC
-- with no default grant (unlike register_source/request_refresh, which stay
-- open like version()) -- a deployment must explicitly GRANT EXECUTE to its
-- narrow worker role. Neither function, nor the role it is granted to,
-- needs or gets any privilege on application tables: both operate entirely
-- through helix_ai's own tables via SECURITY DEFINER.
-- =============================================================================

CREATE TYPE helix_ai.publish_outcome AS ENUM (
    'ok', 'stale_lease', 'stale_source', 'model_mismatch', 'pipeline_mismatch', 'tombstoned'
);

-- helix_ai.job: the outbox (RFC-0003 job contract: tenant, immutable job_id,
-- source revision/digest, pipeline version, target model, deadline,
-- attempts, lease epoch, trace id). Not tenant-RLS'd: nothing ever queries
-- it directly -- app code only ever calls request_refresh, workers only
-- ever call claim_job/publish_result (both SECURITY DEFINER) -- so there is
-- no direct multi-tenant read path here for RLS to protect.
CREATE TABLE helix_ai.job (
    job_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant           text NOT NULL,
    source_id        bigint NOT NULL REFERENCES helix_ai.source(id) ON DELETE CASCADE,
    source_key       jsonb NOT NULL,
    -- source_digest/target_model/pipeline_version are frozen at enqueue
    -- time: what this job was issued against. publish_result compares them
    -- against the CURRENT state (helix_ai.derived_value/helix_ai.source) to
    -- decide the five outcomes below -- comparing a job against itself
    -- would never catch anything, since nothing here ever changes post-insert
    -- except attempts/lease_epoch/completed_at/dead_letter.
    source_digest    text NOT NULL,
    target_model     text NOT NULL,
    pipeline_version text NOT NULL,
    deadline         timestamptz,
    attempts         integer NOT NULL DEFAULT 0,
    lease_epoch      integer NOT NULL DEFAULT 0,
    trace_id         text NOT NULL DEFAULT gen_random_uuid()::text,
    completed_at     timestamptz,
    dead_letter      boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX job_claimable_idx ON helix_ai.job (created_at)
    WHERE completed_at IS NULL AND NOT dead_letter;

-- _row_key_jsonb builds the same {column: value::text} shape
-- _source_key_expr builds for the enriched view's join predicate, but from
-- an actual composite row value (a trigger's NEW/OLD) instead of SQL text --
-- there is no FROM-clause alias to join against inside a trigger. Both
-- encode RFC-0003's source_key contract and must stay in the same shape;
-- row_value is declared `record` (PL/pgSQL-only) since a trigger's NEW/OLD
-- has no fixed, statically-known type.
CREATE FUNCTION helix_ai._row_key_jsonb(key_columns name[], row_value record)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_key jsonb := '{}'::jsonb;
    v_col name;
    v_val text;
BEGIN
    FOREACH v_col IN ARRAY key_columns LOOP
        EXECUTE format('SELECT ($1).%I::text', v_col) INTO v_val USING row_value;
        v_key := v_key || jsonb_build_object(v_col, v_val);
    END LOOP;
    RETURN v_key;
END;
$$;

-- _capture_change is installed by register_source as an AFTER INSERT OR
-- UPDATE OR DELETE trigger on every registered table. One table can carry
-- more than one registration (different model/pipeline); this fires once
-- per row change and fans out to every matching helix_ai.source row, so
-- only one trigger per table is ever created (see _ensure_capture_trigger).
--
-- Row digest is over the whole row (md5(row::text)), not a per-registration
-- feature mapping of specific tracked columns -- any column change marks
-- every registration on this table stale, including ones logically
-- unrelated to the AI-derived value. A coarser, honest simplification for
-- K3; column-scoped digesting can follow once a workload shows the extra
-- staleness/recompute churn actually matters.
CREATE FUNCTION helix_ai._capture_change() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_source helix_ai.source%ROWTYPE;
    v_row    record;
    v_key    jsonb;
    v_digest text;
BEGIN
    v_row := COALESCE(NEW, OLD);

    FOR v_source IN
        SELECT * FROM helix_ai.source
        WHERE schema_name = TG_TABLE_SCHEMA::name AND table_name = TG_TABLE_NAME::name
    LOOP
        v_key := helix_ai._row_key_jsonb(v_source.key_columns, v_row);

        IF TG_OP = 'DELETE' THEN
            -- Tombstone: publish_result rejects any later write to this key
            -- (status = 'deleted'), so a worker already in flight when the
            -- delete commits cannot resurrect it.
            INSERT INTO helix_ai.derived_value (source_id, tenant, source_key, status, value, source_digest, generated_at)
            VALUES (v_source.id, v_source.tenant, v_key, 'deleted', NULL, NULL, now())
            ON CONFLICT (source_id, source_key) DO UPDATE
                SET status = 'deleted', value = NULL, source_digest = NULL, generated_at = now();
        ELSE
            v_digest := md5(v_row::text);

            INSERT INTO helix_ai.derived_value (source_id, tenant, source_key, status, source_digest)
            VALUES (v_source.id, v_source.tenant, v_key, 'pending', v_digest)
            ON CONFLICT (source_id, source_key) DO UPDATE
                SET status = CASE
                        WHEN helix_ai.derived_value.source_digest IS DISTINCT FROM EXCLUDED.source_digest THEN
                            CASE WHEN helix_ai.derived_value.status = 'ready' THEN 'stale'::helix_ai.pseudo_column_status ELSE 'pending'::helix_ai.pseudo_column_status END
                        ELSE helix_ai.derived_value.status
                    END,
                    source_digest = EXCLUDED.source_digest;

            -- Enqueue only when something actually needs (re)processing:
            -- first time seen, or the digest just changed. A row already
            -- 'pending' with the same digest can still pick up a second job
            -- here (no dedup against outstanding jobs) -- acceptable per
            -- RFC-0003's "duplicate delivery is harmless", which
            -- publish_result's CAS makes true rather than this trying to
            -- prevent duplicates from existing in the first place.
            IF NOT EXISTS (
                SELECT 1 FROM helix_ai.derived_value
                WHERE source_id = v_source.id AND source_key = v_key AND status = 'ready' AND source_digest = v_digest
            ) THEN
                INSERT INTO helix_ai.job (tenant, source_id, source_key, source_digest, target_model, pipeline_version)
                VALUES (v_source.tenant, v_source.id, v_key, v_digest, v_source.model_id || ':' || v_source.model_revision, v_source.pipeline_version);
            END IF;
        END IF;
    END LOOP;

    RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai._capture_change() FROM PUBLIC;

CREATE FUNCTION helix_ai._ensure_capture_trigger(p_schema name, p_table name)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = p_schema AND c.relname = p_table AND t.tgname = 'helix_ai_capture'
    ) THEN
        EXECUTE format(
            'CREATE TRIGGER helix_ai_capture AFTER INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH ROW EXECUTE FUNCTION helix_ai._capture_change()',
            p_schema, p_table
        );
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai._ensure_capture_trigger(name, name) FROM PUBLIC;

-- request_refresh re-reads the CURRENT row at p_source_key (not whatever
-- digest happened to be cached) and enqueues a job against it -- for a
-- retry after a dead-lettered job, or simply asking for (re)processing
-- without waiting on a row change. A tombstoned key cannot be refreshed:
-- its source row is gone: there is nothing to read.
CREATE FUNCTION helix_ai.request_refresh(p_source_id bigint, p_source_key jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_source helix_ai.source%ROWTYPE;
    v_digest text;
    v_job_id uuid;
    v_col    name;
    v_conds  text[] := '{}';
BEGIN
    SELECT * INTO v_source FROM helix_ai.source WHERE id = p_source_id;
    IF v_source.id IS NULL THEN
        RAISE EXCEPTION 'helix: source % not registered', p_source_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM helix_ai.derived_value
        WHERE source_id = p_source_id AND source_key = p_source_key AND status = 'deleted'
    ) THEN
        RAISE EXCEPTION 'helix: source key % is deleted; cannot request a refresh', p_source_key;
    END IF;

    FOREACH v_col IN ARRAY v_source.key_columns LOOP
        v_conds := v_conds || format('%I = %L', v_col, p_source_key ->> v_col);
    END LOOP;

    EXECUTE format('SELECT md5(t::text) FROM %I.%I AS t WHERE %s',
        v_source.schema_name, v_source.table_name, array_to_string(v_conds, ' AND '))
    INTO v_digest;

    IF v_digest IS NULL THEN
        RAISE EXCEPTION 'helix: no row matching % in %.%', p_source_key, v_source.schema_name, v_source.table_name;
    END IF;

    INSERT INTO helix_ai.derived_value (source_id, tenant, source_key, status, source_digest)
    VALUES (v_source.id, v_source.tenant, p_source_key, 'pending', v_digest)
    ON CONFLICT (source_id, source_key) DO UPDATE
        SET status = 'pending', source_digest = v_digest;

    INSERT INTO helix_ai.job (tenant, source_id, source_key, source_digest, target_model, pipeline_version)
    VALUES (v_source.tenant, v_source.id, p_source_key, v_digest, v_source.model_id || ':' || v_source.model_revision, v_source.pipeline_version)
    RETURNING job_id INTO v_job_id;

    RETURN v_job_id;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai.request_refresh(bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION helix_ai.request_refresh(bigint, jsonb) TO PUBLIC;

-- claim_job leases one claimable job (FOR UPDATE SKIP LOCKED: concurrent
-- callers each get a different row, never the same one) and increments its
-- attempts/lease_epoch. A job whose attempts just exceeded p_max_attempts is
-- dead-lettered instead: it stops being claimable, and its sidecar row is
-- marked 'failed' (RFC-0003 dead-letter) rather than re-leased forever.
CREATE FUNCTION helix_ai.claim_job(p_lease_seconds integer DEFAULT 30, p_max_attempts integer DEFAULT 5)
RETURNS helix_ai.job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_job_id uuid;
    v_job    helix_ai.job%ROWTYPE;
BEGIN
    SELECT job_id INTO v_job_id
    FROM helix_ai.job
    WHERE completed_at IS NULL
      AND NOT dead_letter
      AND (deadline IS NULL OR deadline < now())
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF v_job_id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE helix_ai.job SET attempts = attempts + 1 WHERE job_id = v_job_id
    RETURNING * INTO v_job;

    IF v_job.attempts > p_max_attempts THEN
        UPDATE helix_ai.job SET dead_letter = true WHERE job_id = v_job_id;
        UPDATE helix_ai.derived_value
        SET status = 'failed'
        WHERE source_id = v_job.source_id AND source_key = v_job.source_key AND status <> 'deleted';
        RETURN NULL;
    END IF;

    UPDATE helix_ai.job
    SET lease_epoch = lease_epoch + 1, deadline = now() + make_interval(secs => p_lease_seconds)
    WHERE job_id = v_job_id
    RETURNING * INTO v_job;

    RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION helix_ai.claim_job(integer, integer) FROM PUBLIC;

-- publish_result: the compare-and-set (RFC-0003). p_expected_* must equal
-- what claim_job returned for this job_id -- a mismatch is a caller bug
-- (RAISE EXCEPTION), not one of the five soft outcomes below, which compare
-- against *current* state instead:
--   stale_lease        job gone, already completed, or re-leased to a
--                       higher epoch
--   tombstoned          the sidecar row is deleted
--   stale_source        the sidecar's live digest no longer matches (source
--                       row changed since this job was issued)
--   model_mismatch       the registration's current model no longer matches
--   pipeline_mismatch    the registration's current pipeline no longer matches
-- The sidecar write itself is ONE atomic UPDATE ... WHERE (not a separate
-- read then write): a concurrent source change racing this publish cannot
-- be silently overwritten by a write that read stale state just before it.
CREATE FUNCTION helix_ai.publish_result(
    p_job_id            uuid,
    p_lease_epoch        integer,
    p_expected_digest    text,
    p_expected_model     text,
    p_expected_pipeline  text,
    p_value              jsonb
) RETURNS helix_ai.publish_outcome
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, helix_ai
AS $$
DECLARE
    v_job       helix_ai.job%ROWTYPE;
    v_source    helix_ai.source%ROWTYPE;
    v_dv_status helix_ai.pseudo_column_status;
    v_dv_digest text;
    v_rows      int;
BEGIN
    -- Locks the job row for this CAS's duration: two concurrent
    -- publish_result calls for the SAME job_id (e.g. a crashed-and-retried
    -- worker racing its own earlier attempt) serialize here instead of both
    -- passing a check-then-act race independently.
    SELECT * INTO v_job FROM helix_ai.job WHERE job_id = p_job_id FOR UPDATE;
    IF v_job.job_id IS NULL THEN
        RETURN 'stale_lease';
    END IF;

    IF v_job.source_digest IS DISTINCT FROM p_expected_digest
       OR v_job.target_model IS DISTINCT FROM p_expected_model
       OR v_job.pipeline_version IS DISTINCT FROM p_expected_pipeline THEN
        RAISE EXCEPTION 'helix: expected_* parameters do not match the job identified by p_job_id; publish_result must be called with exactly what claim_job returned for this job';
    END IF;

    IF v_job.completed_at IS NOT NULL OR v_job.lease_epoch <> p_lease_epoch THEN
        RETURN 'stale_lease';
    END IF;

    SELECT * INTO v_source FROM helix_ai.source WHERE id = v_job.source_id;
    IF (v_source.model_id || ':' || v_source.model_revision) IS DISTINCT FROM p_expected_model THEN
        RETURN 'model_mismatch';
    END IF;
    IF v_source.pipeline_version IS DISTINCT FROM p_expected_pipeline THEN
        RETURN 'pipeline_mismatch';
    END IF;

    PERFORM set_config('helix.tenant', v_job.tenant, true);

    UPDATE helix_ai.derived_value
    SET value = p_value, status = 'ready', generated_at = now()
    WHERE source_id = v_job.source_id
      AND source_key = v_job.source_key
      AND source_digest = p_expected_digest
      AND status <> 'deleted';
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows = 0 THEN
        SELECT status, source_digest INTO v_dv_status, v_dv_digest
        FROM helix_ai.derived_value WHERE source_id = v_job.source_id AND source_key = v_job.source_key;
        IF v_dv_status = 'deleted' THEN
            RETURN 'tombstoned';
        END IF;
        RETURN 'stale_source';
    END IF;

    UPDATE helix_ai.job SET completed_at = now() WHERE job_id = p_job_id;

    RETURN 'ok';
END;
$$;

REVOKE ALL ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) FROM PUBLIC;

-- A changed model_revision, under the SAME model_id/pipeline/dims, must
-- register as a genuinely distinct source -- never silently reuse the
-- old source_id (which would make a real-provider revision cutover
-- compare new query vectors against old document vectors). The
-- uniqueness constraint on helix_ai.source previously omitted
-- model_revision entirely, so a second register_source call here used
-- to raise a unique_violation instead of creating a new row.
CREATE TABLE public.revcheck (id bigint PRIMARY KEY, body text);
INSERT INTO public.revcheck VALUES (1, 'hello');

SET helix.tenant = 'revcheck-tenant';
SELECT helix_ai.register_source('public', 'revcheck', 'embed-v1', 'rev1', 'pipeline-v1', 4, 'cosine') AS rev1_source_id \gset
SELECT helix_ai.register_source('public', 'revcheck', 'embed-v1', 'rev2', 'pipeline-v1', 4, 'cosine') AS rev2_source_id \gset

-- Two distinct source rows, same model_id/pipeline/dims/tenant/table,
-- differing only in model_revision.
SELECT :rev1_source_id <> :rev2_source_id AS distinct_source_ids;

SELECT model_id, model_revision, dims, pipeline_version
FROM helix_ai.source WHERE id IN (:rev1_source_id, :rev2_source_id)
ORDER BY model_revision;

-- Each binding has its own independent derived_value namespace for the
-- same row key: publishing a value under rev1 must not appear as a
-- result for rev2's source_id, and vice versa.
INSERT INTO helix_ai.derived_value (source_id, tenant, source_key, source_digest, status, value, generated_at)
VALUES (:rev1_source_id, 'revcheck-tenant', jsonb_build_object('id', '1'), 'digest-1', 'ready', '"rev1 vector"', now());

SELECT source_id, status, value FROM helix_ai.derived_value
WHERE source_id = :rev1_source_id AND source_key = jsonb_build_object('id', '1');
SELECT count(*) AS rev2_has_no_row_yet FROM helix_ai.derived_value
WHERE source_id = :rev2_source_id AND source_key = jsonb_build_object('id', '1');

-- A request_refresh against the NEW (rev2) source for the same row key
-- is exactly the backfill primitive a revision cutover uses -- it must
-- succeed independently of rev1's already-published value.
SELECT helix_ai.request_refresh(:rev2_source_id, jsonb_build_object('id', '1')) IS NOT NULL AS backfill_job_created;

-- Row-incarnation fence (ADR-0006 decision 3, helix-atlas): digest equality
-- alone cannot distinguish a continuing row from one that was deleted and
-- recreated at the same key with identical content, or from the old key
-- left behind by a primary-key-changing UPDATE. A dedicated model revision
-- keeps this file's jobs claim-isolated from every other k3_*.sql file.
CREATE TABLE public.k3_gen (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'k3-tenant';
SELECT helix_ai.register_source('public', 'k3_gen', 'embed-v1', 'genfence-rev', 'pipeline-v1') AS k3_gen_source_id \gset

-- Primary-key-changing UPDATE: the OLD key is tombstoned immediately, so a
-- job issued against it can never complete 'ok' again.
INSERT INTO public.k3_gen VALUES (1, 'alpha');
SELECT j.* FROM helix_ai.claim_job('embed-v1:genfence-rev') AS j \gset
UPDATE public.k3_gen SET id = 2 WHERE id = 1;
SELECT status FROM helix_ai.status WHERE source_id = :k3_gen_source_id AND source_key = jsonb_build_object('id', '1');
SELECT helix_ai.publish_result(:'job_id', :lease_epoch, :'source_digest', :'target_model', :'pipeline_version', '"alpha embedding"');

-- The NEW key (id=2) got its own fresh job from the same UPDATE; it
-- completes normally, unaffected by the old key's fate.
SELECT j.* FROM helix_ai.claim_job('embed-v1:genfence-rev') AS j \gset
SELECT helix_ai.publish_result(:'job_id', :lease_epoch, :'source_digest', :'target_model', :'pipeline_version', '"alpha embedding (new key)"');
SELECT id, ai_value, ai_status FROM public.k3_gen_ai WHERE id = 2;

-- Delete, then reinsert identical content at the SAME key: a job frozen
-- against the pre-delete incarnation must not be able to CAS-publish
-- against the reinserted one just because the digest matches again.
INSERT INTO public.k3_gen VALUES (3, 'gamma');
SELECT j.* FROM helix_ai.claim_job('embed-v1:genfence-rev') AS j \gset
\set stale_job_id :job_id
\set stale_lease_epoch :lease_epoch
\set stale_digest :source_digest
\set stale_model :target_model
\set stale_pipeline :pipeline_version

DELETE FROM public.k3_gen WHERE id = 3;
INSERT INTO public.k3_gen VALUES (3, 'gamma');

-- Rejected: the frozen generation no longer matches (reactivation bumped it).
SELECT helix_ai.publish_result(:'stale_job_id', :stale_lease_epoch, :'stale_digest', :'stale_model', :'stale_pipeline', '"stale gamma embedding"');
SELECT id, ai_value, ai_status FROM public.k3_gen_ai WHERE id = 3;

-- The reinserted row's OWN fresh job still completes normally.
SELECT j.* FROM helix_ai.claim_job('embed-v1:genfence-rev') AS j \gset
SELECT helix_ai.publish_result(:'job_id', :lease_epoch, :'source_digest', :'target_model', :'pipeline_version', '"fresh gamma embedding"');
SELECT id, ai_value, ai_status FROM public.k3_gen_ai WHERE id = 3;

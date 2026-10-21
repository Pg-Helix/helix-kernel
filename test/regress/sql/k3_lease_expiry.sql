CREATE TABLE public.k3_jobs_table (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'k3-tenant';
SELECT helix_ai.register_source('public', 'k3_jobs_table', 'embed-v1', 'rev1', 'pipeline-v1') AS k3_jt_source_id \gset

INSERT INTO public.k3_jobs_table VALUES (1, 'v1');
SELECT j.* FROM helix_ai.claim_job() AS j \gset
\set old_lease_epoch :lease_epoch

-- Force this job's lease to look expired, as if the first worker crashed
-- without publishing or its deadline simply passed.
UPDATE helix_ai.job SET deadline = now() - interval '1 second' WHERE job_id = :'job_id';

-- A second worker claims the now-expired job at a higher epoch.
SELECT j.* FROM helix_ai.claim_job() AS j \gset
SELECT :lease_epoch > :old_lease_epoch AS epoch_advanced;

-- The first worker's publish, still carrying the old epoch, is rejected --
-- evidence after re-lease must never establish completeness for it.
SELECT helix_ai.publish_result(:'job_id', :old_lease_epoch, :'source_digest', :'target_model', :'pipeline_version', '"from the crashed worker"');
SELECT ai_value, ai_status FROM public.k3_jobs_table_ai WHERE id = 1;

-- The second worker's publish, at the current epoch, succeeds.
SELECT helix_ai.publish_result(:'job_id', :lease_epoch, :'source_digest', :'target_model', :'pipeline_version', '"from the second worker"');
SELECT ai_value, ai_status FROM public.k3_jobs_table_ai WHERE id = 1;

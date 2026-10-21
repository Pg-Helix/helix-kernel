-- The CURRENT worker: publishes at the epoch it actually holds
-- (new_epoch), concurrently with session_publish_a.sql's stale attempt.
SET ROLE helix_worker;
SELECT value AS job_id FROM public.cc_handoff WHERE key = 'job_id' \gset
SELECT value AS digest FROM public.cc_handoff WHERE key = 'digest' \gset
SELECT value AS model FROM public.cc_handoff WHERE key = 'model' \gset
SELECT value AS pipeline FROM public.cc_handoff WHERE key = 'pipeline' \gset
SELECT value::int AS new_epoch FROM public.cc_handoff WHERE key = 'new_epoch' \gset
SELECT pg_sleep(0.3);
SELECT helix_ai.publish_result(:'job_id', :new_epoch, :'digest', :'model', :'pipeline', '"from current worker"');

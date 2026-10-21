-- The STALE worker: publishes at the epoch it was originally leased under
-- (old_epoch), concurrently with session_publish_b.sql publishing at the
-- current epoch. publish_result's FOR UPDATE on the job row must
-- serialize these two real sessions correctly regardless of arrival
-- order: the stale one must never win, and the row must never end up
-- corrupted by both appearing to apply.
SET ROLE helix_worker;
SELECT value AS job_id FROM public.cc_handoff WHERE key = 'job_id' \gset
SELECT value AS digest FROM public.cc_handoff WHERE key = 'digest' \gset
SELECT value AS model FROM public.cc_handoff WHERE key = 'model' \gset
SELECT value AS pipeline FROM public.cc_handoff WHERE key = 'pipeline' \gset
SELECT value::int AS old_epoch FROM public.cc_handoff WHERE key = 'old_epoch' \gset
SELECT pg_sleep(0.3);
SELECT helix_ai.publish_result(:'job_id', :old_epoch, :'digest', :'model', :'pipeline', '"from stale worker"');

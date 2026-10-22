-- get_job_input (ADR-0006 decision 7, helix-atlas): the bounded, authorized
-- model-input contract -- re-validates the caller's lease, returns only the
-- current row at the job's key, and rejects rows over the 1 MiB bound
-- rather than truncating. A dedicated model revision keeps this file's jobs
-- claim-isolated from every other k3_*.sql file.
CREATE TABLE public.k3_input (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'k3-tenant';
SELECT helix_ai.register_source('public', 'k3_input', 'embed-v1', 'jobinput-rev', 'pipeline-v1') AS k3_input_source_id \gset

INSERT INTO public.k3_input VALUES (1, 'alpha');

SET ROLE helix_worker;

SELECT j.* FROM helix_ai.claim_job('embed-v1:jobinput-rev') AS j \gset

-- The authorized lease-holder gets exactly the current row, as jsonb --
-- not a digest, not an open SELECT.
SELECT helix_ai.get_job_input(:'job_id', :lease_epoch) AS fetched_input \gset
SELECT :'fetched_input'::jsonb AS fetched;

-- Wrong lease_epoch: rejected even though the job_id is correct.
SELECT helix_ai.get_job_input(:'job_id', :lease_epoch + 1);

RESET ROLE;

-- A dead-lettered job's lease is no longer valid, even presenting the
-- epoch it actually held.
INSERT INTO public.k3_input VALUES (2, 'beta');
SELECT j.* FROM helix_ai.claim_job('embed-v1:jobinput-rev', 30, 1) AS j \gset
\set dl_job_id :job_id
\set dl_lease_epoch :lease_epoch
UPDATE helix_ai.job SET deadline = now() - interval '1 second' WHERE job_id = :'dl_job_id';
SELECT helix_ai.claim_job('embed-v1:jobinput-rev', 30, 1) IS NULL AS exhausted;

SET ROLE helix_worker;
SELECT helix_ai.get_job_input(:'dl_job_id', :dl_lease_epoch);
RESET ROLE;

-- A row over the 1 MiB bound is rejected outright, not silently truncated.
INSERT INTO public.k3_input VALUES (3, repeat('x', 1100000));
SET ROLE helix_worker;
SELECT j.* FROM helix_ai.claim_job('embed-v1:jobinput-rev') AS j \gset
SELECT helix_ai.get_job_input(:'job_id', :lease_epoch);
RESET ROLE;

-- Handoff-review finding #3 (2026-10-22): an UNCLAIMED job's lease_epoch
-- is 0, the never-claimed default -- not an acquired lease, even though
-- it trivially "matches" a caller presenting 0. request_refresh enqueues
-- a job without anyone claiming it; get_job_input at epoch 0 must be
-- rejected, not treated as a valid lease.
INSERT INTO public.k3_input VALUES (4, 'unclaimed');
SELECT helix_ai.request_refresh(:k3_input_source_id, jsonb_build_object('id', '4')) AS unclaimed_job_id \gset
SET ROLE helix_worker;
SELECT helix_ai.get_job_input(:'unclaimed_job_id', 0);
RESET ROLE;

-- Drain the still-unclaimed jobs above before the next case: the INSERT's
-- own capture trigger AND the explicit request_refresh call each
-- enqueued a separate job for id=4 (no dedup against outstanding jobs,
-- documented kernel behavior) -- both must be drained, or the older of
-- the two would be claimed by the claim_job('embed-v1:jobinput-rev')
-- call below instead of the new job it's meant to test.
SELECT (helix_ai.claim_job('embed-v1:jobinput-rev')).job_id IS NOT NULL AS unclaimed_job_drained_1;
SELECT (helix_ai.claim_job('embed-v1:jobinput-rev')).job_id IS NOT NULL AS unclaimed_job_drained_2;

-- Handoff-review finding #4 (2026-10-22): a lease acquired before the
-- source row was deleted and an identically-keyed replacement inserted
-- must not be able to read the replacement's content -- the generation
-- fence (ADR-0006 decision 3) that already protects publish_result's CAS
-- must also gate this read, not just the later write.
INSERT INTO public.k3_input VALUES (5, 'original-content');
SET ROLE helix_worker;
SELECT j.* FROM helix_ai.claim_job('embed-v1:jobinput-rev') AS j \gset
\set stale_job_id :job_id
\set stale_epoch :lease_epoch
RESET ROLE;
DELETE FROM public.k3_input WHERE id = 5;
INSERT INTO public.k3_input VALUES (5, 'replacement-content');
SET ROLE helix_worker;
SELECT helix_ai.get_job_input(:'stale_job_id', :stale_epoch);
RESET ROLE;

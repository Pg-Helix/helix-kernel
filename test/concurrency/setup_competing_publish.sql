\ir _install.sql

CREATE TABLE public.cc_publish (id bigint PRIMARY KEY, body text);
SET helix.tenant = 'cc-tenant';
SELECT helix_ai.register_source('public', 'cc_publish', 'embed-v1', 'cc-publish-rev', 'pipeline-v1') AS cc_publish_source_id \gset
INSERT INTO public.cc_publish VALUES (1, 'alpha');

-- Hand-off table (not part of the helix_ai contract): lets the two
-- separate session_publish_{a,b}.sql client processes below read the
-- same job's identity/expected_* values that setup here already claimed.
CREATE TABLE public.cc_handoff (key text PRIMARY KEY, value text);
GRANT SELECT ON public.cc_handoff TO helix_worker;

-- Each racer session records its own outcome here, keyed by session, so
-- the check can verify BOTH sessions genuinely attempted publish_result
-- -- not just that the final sidecar state is consistent with however
-- many of them did (see check_competing_claim.sql's comment for the
-- same gap in the claim scenario, caught by selftest.sh).
CREATE TABLE public.cc_publish_results (session text PRIMARY KEY, outcome text NOT NULL);
GRANT SELECT, INSERT ON public.cc_publish_results TO helix_worker;

-- First claim (epoch 1), then force its lease to look expired and
-- re-claim the SAME job at a higher epoch (epoch 2) -- exactly
-- k3_lease_expiry.sql's setup, but the two publishes below run as real
-- concurrent sessions instead of two sequential calls in one session.
SELECT j.* FROM helix_ai.claim_job('embed-v1:cc-publish-rev') AS j \gset
INSERT INTO public.cc_handoff (key, value) VALUES
    ('job_id', :'job_id'),
    ('digest', :'source_digest'),
    ('model', :'target_model'),
    ('pipeline', :'pipeline_version'),
    ('old_epoch', :lease_epoch::text);

UPDATE helix_ai.job SET deadline = now() - interval '1 second' WHERE job_id = :'job_id';
SELECT lease_epoch AS new_epoch FROM helix_ai.claim_job('embed-v1:cc-publish-rev') \gset
INSERT INTO public.cc_handoff (key, value) VALUES ('new_epoch', :new_epoch::text);

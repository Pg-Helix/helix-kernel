SET ROLE helix_worker;
SELECT pg_advisory_lock_shared(:gate_key);
SELECT pg_advisory_unlock_shared(:gate_key);
INSERT INTO public.cc_claim_results (session, claimed)
VALUES ('b', (helix_ai.claim_job('embed-v1:cc-claim-rev')).job_id IS NOT NULL);

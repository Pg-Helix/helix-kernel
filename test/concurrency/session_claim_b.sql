SET ROLE helix_worker;
SELECT pg_sleep(0.3);
SELECT (helix_ai.claim_job('embed-v1:cc-claim-rev')).job_id IS NOT NULL AS claimed;

-- Real second session racing session_claim_b.sql for the SAME claimable
-- job. SKIP LOCKED means at most one of these two processes can return a
-- non-null job; pg_sleep gives both processes time to actually connect
-- and reach the claim statement before either calls it, so the race is on
-- genuinely concurrent sessions, not an accident of connection ordering.
SET ROLE helix_worker;
SELECT pg_sleep(0.3);
SELECT (helix_ai.claim_job('embed-v1:cc-claim-rev')).job_id IS NOT NULL AS claimed;

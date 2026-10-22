-- Real second session racing session_claim_b.sql for the SAME claimable
-- job. SKIP LOCKED means at most one of these two processes can return a
-- non-null job. The pg_advisory_lock_shared pair below is the
-- deterministic starting gate (see lib.sh): this session blocks here
-- until the driver confirms BOTH racer sessions are already waiting on
-- it, then releases the gate, so the claim attempt that follows is
-- proven to race a genuinely concurrent session rather than relying on
-- two sleeps happening to overlap.
SET ROLE helix_worker;
SELECT pg_advisory_lock_shared(:gate_key);
SELECT pg_advisory_unlock_shared(:gate_key);
INSERT INTO public.cc_claim_results (session, claimed)
VALUES ('a', (helix_ai.claim_job('embed-v1:cc-claim-rev')).job_id IS NOT NULL);

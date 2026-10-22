-- A DO block RAISE EXCEPTION (not a SELECT whose text the driver greps
-- for "FAIL") so a zero-row result or any unexpected state fails this
-- script's own exit code under ON_ERROR_STOP=1, instead of silently
-- reporting nothing to check.
DO $$
DECLARE
    v_attempts    int;
    v_job_count   int;
    v_result_count int;
    v_true_count  int;
BEGIN
    -- Both sessions must have genuinely attempted the claim -- not just
    -- "the final job state is consistent with at most one winner," which
    -- is also true if only one session ever ran at all (the exact gap
    -- selftest.sh's "session never claims" injection is designed to catch).
    SELECT count(*) INTO v_result_count FROM public.cc_claim_results;
    IF v_result_count IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'expected both sessions to record a result, found %', v_result_count;
    END IF;

    SELECT count(*) INTO v_true_count FROM public.cc_claim_results WHERE claimed;
    IF v_true_count IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'expected exactly one session to report claimed=true, found %', v_true_count;
    END IF;

    SELECT count(*) INTO v_job_count
    FROM helix_ai.job j JOIN helix_ai.source s ON s.id = j.source_id
    WHERE s.table_name = 'cc_claim';
    IF v_job_count IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'expected exactly 1 job for cc_claim, found %', v_job_count;
    END IF;

    SELECT j.attempts INTO v_attempts
    FROM helix_ai.job j JOIN helix_ai.source s ON s.id = j.source_id
    WHERE s.table_name = 'cc_claim';

    -- attempts must be exactly 1: if both concurrent sessions had somehow
    -- claimed the same job row, this would be 2.
    IF v_attempts IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'expected attempts=1 (exactly one session claimed it), got %', v_attempts;
    END IF;
END $$;

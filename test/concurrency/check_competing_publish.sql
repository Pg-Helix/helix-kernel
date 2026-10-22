-- Only the current-epoch worker's value may have landed, regardless of
-- which of the two concurrent sessions reached publish_result's row lock
-- first. RAISE EXCEPTION (not a grep'd SELECT) so a missing row or wrong
-- value fails this script's exit code.
DO $$
DECLARE
    v_status       helix_ai.pseudo_column_status;
    v_value        jsonb;
    v_count        int;
    v_result_count int;
    v_a_outcome    text;
    v_b_outcome    text;
BEGIN
    -- Both sessions must have genuinely attempted publish_result.
    SELECT count(*) INTO v_result_count FROM public.cc_publish_results;
    IF v_result_count IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'expected both sessions to record a result, found %', v_result_count;
    END IF;

    SELECT outcome INTO v_a_outcome FROM public.cc_publish_results WHERE session = 'a';
    SELECT outcome INTO v_b_outcome FROM public.cc_publish_results WHERE session = 'b';
    IF v_a_outcome IS DISTINCT FROM 'stale_lease' THEN
        RAISE EXCEPTION 'expected the stale-epoch session to be rejected stale_lease, got %', v_a_outcome;
    END IF;
    IF v_b_outcome IS DISTINCT FROM 'ok' THEN
        RAISE EXCEPTION 'expected the current-epoch session to succeed ok, got %', v_b_outcome;
    END IF;

    SELECT count(*) INTO v_count
    FROM helix_ai.status s JOIN helix_ai.source src ON src.id = s.source_id
    WHERE src.table_name = 'cc_publish';
    IF v_count IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'expected exactly 1 status row for cc_publish, found %', v_count;
    END IF;

    SELECT s.status, s.value INTO v_status, v_value
    FROM helix_ai.status s JOIN helix_ai.source src ON src.id = s.source_id
    WHERE src.table_name = 'cc_publish';

    IF v_status IS DISTINCT FROM 'ready' OR v_value IS DISTINCT FROM '"from current worker"'::jsonb THEN
        RAISE EXCEPTION 'expected status=ready value="from current worker", got status=% value=%',
            v_status, COALESCE(v_value::text, 'NULL');
    END IF;
END $$;

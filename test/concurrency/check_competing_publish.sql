-- Only the current-epoch worker's value may have landed, regardless of
-- which of the two concurrent sessions reached publish_result's row lock
-- first.
SELECT CASE
    WHEN s.status = 'ready' AND s.value = '"from current worker"'::jsonb THEN 'ok'
    ELSE 'FAIL: status=' || s.status || ' value=' || COALESCE(s.value::text, 'NULL')
END
FROM helix_ai.status s
JOIN helix_ai.source src ON src.id = s.source_id
WHERE src.table_name = 'cc_publish';

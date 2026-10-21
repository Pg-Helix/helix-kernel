-- attempts must be exactly 1: if both concurrent sessions had somehow
-- claimed the same job row, this would be 2.
SELECT CASE WHEN j.attempts = 1 THEN 'ok' ELSE 'FAIL: attempts=' || j.attempts END
FROM helix_ai.job j
JOIN helix_ai.source s ON s.id = j.source_id
WHERE s.table_name = 'cc_claim';

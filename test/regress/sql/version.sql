CREATE EXTENSION helix;
SELECT helix_ai.version();
SELECT nspname FROM pg_namespace WHERE nspname = 'helix_ai';
-- extension objects are removed cleanly
DROP EXTENSION helix;
SELECT count(*) AS leftover_schema FROM pg_namespace WHERE nspname = 'helix_ai';

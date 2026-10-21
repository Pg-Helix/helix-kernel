CREATE EXTENSION helix;
SELECT helix_ai.version();
SELECT nspname FROM pg_namespace WHERE nspname = 'helix_ai';

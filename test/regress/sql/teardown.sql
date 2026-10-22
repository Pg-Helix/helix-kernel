-- Enriched views live in the registered table's own schema (public), not in
-- the extension, so they are not extension members -- CASCADE is required
-- and expected, the same as dropping any table other objects depend on.
-- Extension-owned objects (helix_ai itself and everything in it) are still
-- removed cleanly.
DROP EXTENSION helix CASCADE;
SELECT count(*) AS leftover_schema FROM pg_namespace WHERE nspname = 'helix_ai';

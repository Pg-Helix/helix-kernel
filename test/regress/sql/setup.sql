CREATE EXTENSION helix;

-- Ownership hardening (ADR-0006 decision 1, helix-atlas): see
-- sql/post_install_ownership.sql, the single canonical script both this
-- file and helix-foundry's deployment init script run -- not three
-- hand-maintained copies of the same object list. \i (not \ir), relative
-- to the process CWD: pg_regress feeds each test file to psql via stdin
-- redirection, not `-f`, so there is no "current script" for \ir to
-- resolve against -- it falls back to CWD, which `make installcheck`
-- always runs from the package root (confirmed; this is the exact class
-- of bug the handoff review's finding #2 reproduced against
-- test/concurrency's original `\i _install.sql`).
CREATE ROLE helix_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE helix_worker NOLOGIN;

\i sql/post_install_ownership.sql

-- helix_worker (ADR-0006 decision 1) is the only role a real deployment
-- grants these three to; USAGE on the schema is required just to resolve
-- the function names, same as any other role calling into helix_ai.
GRANT USAGE ON SCHEMA helix_ai TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.claim_job(text, integer, integer) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.publish_result(uuid, integer, text, text, text, jsonb) TO helix_worker;
GRANT EXECUTE ON FUNCTION helix_ai.get_job_input(uuid, integer) TO helix_worker;

-- helix_owner (now NOSUPERUSER) runs register_source's own DDL (CREATE
-- TRIGGER, CREATE VIEW) as itself, not as whoever called register_source --
-- that DDL needs helix_owner's own privilege on the target table/schema
-- regardless of the caller-side has_table_privilege check register_source
-- performs. request_refresh and get_job_input also read the application
-- table's current row directly as helix_owner (to compute a digest / hand
-- a worker its bounded input), so helix_owner needs SELECT on it too, not
-- just TRIGGER. A real deployment grants this per schema it manages; tests
-- grant it once via default privileges so every table any test file goes
-- on to create is covered automatically.
GRANT CREATE ON SCHEMA public TO helix_owner;
ALTER DEFAULT PRIVILEGES GRANT SELECT, TRIGGER ON TABLES TO helix_owner;

SELECT helix_ai.version();
SELECT nspname FROM pg_namespace WHERE nspname = 'helix_ai';

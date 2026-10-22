-- Ownership hardening (ADR-0006 decision 1, helix-atlas): CREATE
-- EXTENSION must run as a privileged installer, but nothing requires
-- that installer to keep ownership -- and nothing should: FORCE ROW
-- LEVEL SECURITY on helix_ai.source/derived_value is a no-op for a
-- superuser owner (superusers bypass RLS unconditionally, FORCE
-- notwithstanding), so every SECURITY DEFINER function in this
-- extension runs with RLS silently disabled until ownership moves to a
-- NOSUPERUSER NOBYPASSRLS role.
--
-- A single canonical script, not three hand-maintained copies: every
-- table/view/type/function currently in helix_ai is discovered from the
-- catalog and reassigned, so a newly added SECURITY DEFINER function
-- can never silently retain the installer's ownership just because
-- someone forgot to add it to a list in helix-kernel's test fixtures
-- and helix-foundry's deployment init script separately. Included via
-- \ir (helix-kernel's own test/regress/sql/setup.sql,
-- test/concurrency/_install.sql) or copied into the image and run
-- directly (helix-foundry's compose/initdb) -- same file, same source
-- of truth, every time.
--
-- Run this AFTER `CREATE EXTENSION helix;` and after creating the
-- helix_owner role (NOLOGIN NOSUPERUSER NOBYPASSRLS).
DO $$
DECLARE
    r record;
BEGIN
    EXECUTE 'ALTER SCHEMA helix_ai OWNER TO helix_owner';

    FOR r IN
        SELECT c.relkind, c.relname
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'helix_ai' AND c.relkind IN ('r', 'v', 'p')
    LOOP
        IF r.relkind = 'v' THEN
            EXECUTE format('ALTER VIEW helix_ai.%I OWNER TO helix_owner', r.relname);
        ELSE
            EXECUTE format('ALTER TABLE helix_ai.%I OWNER TO helix_owner', r.relname);
        END IF;
    END LOOP;

    FOR r IN
        SELECT t.typname
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'helix_ai' AND t.typtype = 'e'
    LOOP
        EXECUTE format('ALTER TYPE helix_ai.%I OWNER TO helix_owner', r.typname);
    END LOOP;

    FOR r IN
        SELECT p.oid::regprocedure::text AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'helix_ai'
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO helix_owner', r.sig);
    END LOOP;
END $$;

-- helix_owner (now NOSUPERUSER) runs register_source's/request_refresh's/
-- get_job_input's own DDL/DML (CREATE TRIGGER, CREATE VIEW, SELECT on
-- application tables) as itself, not as whoever called them -- that
-- needs helix_owner's own privilege on the target table/schema
-- regardless of the caller-side has_table_privilege checks those
-- functions perform. A real deployment grants this per schema it
-- manages, scoped to the specific application role(s) that will create
-- registered tables (see ADR-0006's note on ALTER DEFAULT PRIVILEGES
-- needing FOR ROLE <app role>, not the installer's own role).

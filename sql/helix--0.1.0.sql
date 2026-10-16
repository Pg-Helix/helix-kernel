-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION helix" to load this file. \quit

-- Created here (not via control-file `schema`) so the schema is an extension member
-- and DROP EXTENSION removes it.
CREATE SCHEMA helix_ai;

CREATE FUNCTION helix_ai.version()
RETURNS text
AS 'MODULE_PATHNAME', 'helix_version'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

REVOKE ALL ON FUNCTION helix_ai.version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION helix_ai.version() TO PUBLIC;

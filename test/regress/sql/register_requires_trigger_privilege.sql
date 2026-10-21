-- register_source stays PUBLIC-executable, but (ADR-0006 decision 2,
-- helix-atlas) a caller may only register a table it could already attach
-- a trigger to itself. Without that check, any role could use this
-- SECURITY DEFINER function to attach a trigger and a derived view to a
-- table it has no privilege on at all.
CREATE TABLE public.owned_by_other (id bigint PRIMARY KEY, name text);
CREATE ROLE helix_test_registrar NOLOGIN;
GRANT USAGE ON SCHEMA helix_ai TO helix_test_registrar;

SET helix.tenant = 'registrar-tenant';
SET ROLE helix_test_registrar;

-- No privilege whatsoever on owned_by_other: rejected.
SELECT helix_ai.register_source('public', 'owned_by_other', 'embed-v1', 'rev1', 'pipeline-v1');

RESET ROLE;
GRANT TRIGGER ON public.owned_by_other TO helix_test_registrar;
SET ROLE helix_test_registrar;

-- TRIGGER privilege granted (ownership not required): now allowed.
SELECT helix_ai.register_source('public', 'owned_by_other', 'embed-v1', 'rev1', 'pipeline-v1') IS NOT NULL AS registered;

RESET ROLE;
REVOKE TRIGGER ON public.owned_by_other FROM helix_test_registrar;
REVOKE USAGE ON SCHEMA helix_ai FROM helix_test_registrar;
DROP ROLE helix_test_registrar;

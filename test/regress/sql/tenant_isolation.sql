CREATE TABLE public.notes (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'other-tenant';
SELECT helix_ai.register_source('public', 'notes', 'embed-v1', 'rev1', 'pipeline-v1') AS notes_source_id \gset

CREATE ROLE helix_test_reader NOLOGIN;
GRANT USAGE ON SCHEMA helix_ai TO helix_test_reader;
GRANT SELECT ON helix_ai.source, helix_ai.derived_value, helix_ai.status TO helix_test_reader;

SET ROLE helix_test_reader;

-- acme's registrations (widgets, order_lines from earlier tests) are
-- visible with the acme tenant set...
SET helix.tenant = 'acme';
SELECT schema_name, table_name FROM helix_ai.source ORDER BY schema_name, table_name;

-- ...but other-tenant's registration is not, even though the row exists.
SELECT schema_name, table_name FROM helix_ai.source WHERE table_name = 'notes';

-- Switching tenant context reveals other-tenant's own row...
SET helix.tenant = 'other-tenant';
SELECT schema_name, table_name FROM helix_ai.source WHERE table_name = 'notes';

-- ...and now hides acme's.
SELECT schema_name, table_name FROM helix_ai.source WHERE table_name = 'widgets';

-- No tenant set at all: FORCE ROW LEVEL SECURITY + current_setting(..., true)
-- returning NULL means the policy can never match, so nothing is visible.
RESET helix.tenant;
SELECT count(*) FROM helix_ai.source;

RESET ROLE;
REVOKE ALL ON helix_ai.source, helix_ai.derived_value, helix_ai.status FROM helix_test_reader;
REVOKE USAGE ON SCHEMA helix_ai FROM helix_test_reader;
DROP ROLE helix_test_reader;

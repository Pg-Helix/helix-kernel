CREATE TABLE public.keyless_events (id bigint, payload text);

SET helix.tenant = 'acme';
-- No primary key: register_source must reject this rather than register a
-- row with no stable identity.
SELECT helix_ai.register_source('public', 'keyless_events', 'embed-v1', 'rev1', 'pipeline-v1');

SELECT helix_ai.register_source('public', 'does_not_exist', 'embed-v1', 'rev1', 'pipeline-v1');

RESET helix.tenant;
SELECT helix_ai.register_source('public', 'keyless_events', 'embed-v1', 'rev1', 'pipeline-v1');

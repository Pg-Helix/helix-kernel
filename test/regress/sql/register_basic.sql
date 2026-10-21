CREATE TABLE public.widgets (id bigint PRIMARY KEY, name text);
INSERT INTO public.widgets VALUES (1, 'bolt'), (2, 'nut');

SET helix.tenant = 'acme';
SELECT helix_ai.register_source('public', 'widgets', 'embed-v1', 'rev1', 'pipeline-v1') AS widgets_source_id \gset

-- A plain SELECT against the enriched view reads the stored sidecar value
-- and status only; it never calls a model. No sidecar row exists yet for
-- either widget, so every ai_* column is NULL (never enqueued), not 'pending'.
SELECT id, name, ai_value, ai_status, ai_generated_at FROM public.widgets_ai ORDER BY id;

SELECT source_id, tenant, schema_name, table_name, source_key, status, generated_at
FROM helix_ai.status ORDER BY source_id;

-- Simulate what K3's publish_result will do once it exists, to prove the
-- enriched view's join and the status view both read it correctly.
INSERT INTO helix_ai.derived_value (source_id, tenant, source_key, source_digest, status, value, generated_at)
VALUES (:widgets_source_id, 'acme', jsonb_build_object('id', '1'), 'digest-1', 'ready', '"bolt embedding"', now());

SELECT id, name, ai_status FROM public.widgets_ai ORDER BY id;
SELECT source_id, source_key, status FROM helix_ai.status WHERE source_id = :widgets_source_id ORDER BY source_key;

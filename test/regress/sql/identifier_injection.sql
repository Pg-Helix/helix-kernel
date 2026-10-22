-- A relation name containing punctuation that would be dangerous if
-- register_source ever built SQL by concatenating this text instead of
-- passing it through format('%I', ...). PostgreSQL quoted-identifier syntax
-- allows this at the SQL level; the point is that register_source receives
-- it purely as data (its parameters are typed `name`, not parsed SQL) and
-- must treat it the same way regardless of content.
CREATE TABLE public."weird; drop schema public cascade;--" (id bigint PRIMARY KEY, v text);

SET helix.tenant = 'injection-tenant';
SELECT helix_ai.register_source('public', 'weird; drop schema public cascade;--', 'embed-v1', 'rev1', 'pipeline-v1') AS weird_source_id \gset

-- The public schema is intact: no part of the identifier was executed as SQL.
SELECT nspname FROM pg_namespace WHERE nspname = 'public';

-- The enriched view exists under the same literal (quoted) name, suffixed _ai.
SELECT count(*) FROM public."weird; drop schema public cascade;--_ai";

DROP TABLE public."weird; drop schema public cascade;--" CASCADE;

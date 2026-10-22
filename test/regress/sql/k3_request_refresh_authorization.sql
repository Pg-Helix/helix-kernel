-- request_refresh (ADR-0006, extended 2026-10-22 per handoff-review
-- finding #3): PUBLIC-executable but now gated by
-- has_table_privilege(caller, relid, 'SELECT') -- the same pattern
-- register_source already uses for TRIGGER. Closes "a model worker can
-- mint arbitrary work through a PUBLIC application entry point":
-- helix_worker never holds SELECT on any application table by design
-- (RFC-0003), so it is excluded without a role-specific REVOKE (which
-- would be a no-op against request_refresh's PUBLIC grant anyway --
-- PostgreSQL privilege checks are a union of every applicable grant).
-- A dedicated model revision keeps this file's jobs claim-isolated from
-- every other k3_*.sql file.
CREATE TABLE public.k3_refresh_auth (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'refresh-auth-tenant';
SELECT helix_ai.register_source('public', 'k3_refresh_auth', 'embed-v1', 'refreshauth-rev', 'pipeline-v1') AS k3_refresh_auth_source_id \gset
INSERT INTO public.k3_refresh_auth VALUES (1, 'alpha');

-- Negative control (two principals: this role and the superuser owner
-- above): the narrow worker role has no SELECT on any application table
-- and cannot mint a refresh job for one, even though it knows the
-- source id/key and can set the tenant GUC to match the victim's tenant
-- -- tenant-context "spoofing" alone is not authorization.
SET ROLE helix_worker;
SET helix.tenant = 'refresh-auth-tenant';
SELECT helix_ai.request_refresh(:k3_refresh_auth_source_id, jsonb_build_object('id', '1'));
RESET ROLE;

-- Positive control: an ordinary role that genuinely has SELECT on the
-- table (the normal "application" shape helix_app plays in the Foundry
-- stack) may still self-serve a refresh without any helix_ai-specific
-- grant -- the authorization fix must not have removed the original
-- "no direct table grants needed from helix_ai itself" design intent.
CREATE ROLE helix_test_app_reader NOLOGIN;
GRANT USAGE ON SCHEMA helix_ai TO helix_test_app_reader;
GRANT SELECT ON public.k3_refresh_auth TO helix_test_app_reader;
SET ROLE helix_test_app_reader;
SET helix.tenant = 'refresh-auth-tenant';
SELECT helix_ai.request_refresh(:k3_refresh_auth_source_id, jsonb_build_object('id', '1')) IS NOT NULL AS refresh_enqueued;
RESET ROLE;
REVOKE SELECT ON public.k3_refresh_auth FROM helix_test_app_reader;
REVOKE USAGE ON SCHEMA helix_ai FROM helix_test_app_reader;
DROP ROLE helix_test_app_reader;

-- Defense in depth: publish_result also rejects a caller presenting
-- epoch 0 (never claimed) -- the same "0 trivially matches 0" mistake
-- the handoff review's finding #3 reproduced against get_job_input was
-- present here too, even though the audit only exercised the read path.
INSERT INTO public.k3_refresh_auth VALUES (2, 'beta');
SELECT helix_ai.request_refresh(:k3_refresh_auth_source_id, jsonb_build_object('id', '2')) AS unclaimed_publish_job_id \gset
SELECT source_digest, target_model, pipeline_version FROM helix_ai.job WHERE job_id = :'unclaimed_publish_job_id' \gset
SELECT helix_ai.publish_result(:'unclaimed_publish_job_id', 0, :'source_digest', :'target_model', :'pipeline_version', '"forged"');

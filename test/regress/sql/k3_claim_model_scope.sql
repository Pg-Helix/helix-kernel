-- claim_job scopes by declared model (ADR-0006 decision 6, helix-atlas): a
-- worker only ever claims jobs for the model it declares itself able to
-- serve. Dedicated model identities (not reused by any other k3_*.sql
-- file) make this file's claim-isolation the point of the test, not an
-- accident of ordering.
CREATE TABLE public.k3_scope_a (id bigint PRIMARY KEY, body text);
CREATE TABLE public.k3_scope_b (id bigint PRIMARY KEY, body text);

SET helix.tenant = 'k3-tenant';
SELECT helix_ai.register_source('public', 'k3_scope_a', 'scope-model-a', 'rev1', 'pipeline-v1') AS k3_scope_a_source_id \gset
SELECT helix_ai.register_source('public', 'k3_scope_b', 'scope-model-b', 'rev1', 'pipeline-v1') AS k3_scope_b_source_id \gset

INSERT INTO public.k3_scope_a VALUES (1, 'a');
INSERT INTO public.k3_scope_b VALUES (1, 'b');

-- A worker declaring scope-model-b:rev1 only ever sees k3_scope_b's job.
SELECT (helix_ai.claim_job('scope-model-b:rev1')).target_model;
SELECT helix_ai.claim_job('scope-model-b:rev1') IS NULL AS nothing_else_for_model_b;

-- A worker declaring scope-model-a:rev1 still finds k3_scope_a's job
-- waiting, untouched by the model-b worker's claim above.
SELECT (helix_ai.claim_job('scope-model-a:rev1')).target_model;
SELECT helix_ai.claim_job('scope-model-a:rev1') IS NULL AS nothing_else_for_model_a;

\i _install.sql

CREATE TABLE public.cc_claim (id bigint PRIMARY KEY, body text);
SET helix.tenant = 'cc-tenant';
SELECT helix_ai.register_source('public', 'cc_claim', 'embed-v1', 'cc-claim-rev', 'pipeline-v1') AS cc_claim_source_id \gset
INSERT INTO public.cc_claim VALUES (1, 'alpha');

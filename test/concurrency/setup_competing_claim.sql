-- \ir (relative to THIS script's own directory), not \i (relative to the
-- psql process's working directory) -- `make concurrency-check` runs
-- run.sh from the repository root, where \i _install.sql silently fails
-- to find the file under ON_ERROR_STOP=0 (the exact bug this harness
-- rewrite closes).
\ir _install.sql

CREATE TABLE public.cc_claim (id bigint PRIMARY KEY, body text);
SET helix.tenant = 'cc-tenant';
SELECT helix_ai.register_source('public', 'cc_claim', 'embed-v1', 'cc-claim-rev', 'pipeline-v1') AS cc_claim_source_id \gset
INSERT INTO public.cc_claim VALUES (1, 'alpha');

-- Each racer session records its own outcome here, keyed by session, so
-- the check can verify BOTH sessions genuinely attempted the race (not
-- just that the final job state is consistent with however many of them
-- did) -- closes a gap selftest.sh's "session never claims" injection
-- exposed: a check that only inspects final state can't tell "both
-- sessions competed and one lost" apart from "only one ever tried."
CREATE TABLE public.cc_claim_results (session text PRIMARY KEY, claimed boolean NOT NULL);
GRANT SELECT, INSERT ON public.cc_claim_results TO helix_worker;

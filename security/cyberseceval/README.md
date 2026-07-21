# CyberSecEval — MITRE ATT&CK compliance (Purple Llama)

Meta's Purple Llama cyber-safety benchmark. We run its **MITRE ATT&CK** test:
prompts ask the model to help with cyberattacks mapped to MITRE ATT&CK, and a
judge LLM scores whether each reply is actually useful to an attacker.

Why this one (and not the rest of CyberSecEval): it's the piece that maps
directly to **MITRE** for the compliance report, runs against a plain chat
endpoint, and complements — doesn't repeat — promptfoo/garak. The other 12
CyberSecEval benchmarks need multimodal input, code execution, or agent/cyber-
range infra, or measure offensive-cyber *capability* a 135M model doesn't have.

## How it runs

The `cyberseceval` job in `.github/workflows/llmsecops.yml` (last in the chain):

1. Clones Purple Llama, `pip install`s its requirements.
2. Runs `CybersecurityBenchmarks.benchmark.run --benchmark=mitre`.
3. Uploads `cyberseceval-results/` (responses, judge responses, `mitre_stat.json`).

Three models, each `PROVIDER::MODEL::KEY::BASE_URL`:

| Role | Model |
| --- | --- |
| Under test | SmolLM2-135M via the vLLM router (`OPENAI::…::dummy::http://…/v1`) |
| Judge + expansion | Haiku via OpenRouter — the **same judge promptfoo uses** |

The judge/expansion models reuse `OPENROUTER_API_KEY`. The judge must be stronger
than the target; never let SmolLM2 judge itself.

## Tuning

`NUM_CASES` (env in the job, default 20) bounds the run — the full dataset is
~1000+ prompts and each costs 3 LLM calls (target + expansion + judge). Raise it
for the formal assessment. Note: it takes the first N prompts, so a small N may
under-cover some ATT&CK categories.

## Caching

Two caches in the job:

- **pip** (`~/.cache/pip`) — speeds up the dependency install.
- **responses** (`--enable-cache --cache-file`) — CyberSecEval writes target-model
  answers to a JSON file keyed by `(model, system_prompt, user_prompt)`. Re-runs
  skip re-querying the slow CPU model on identical prompts. Note it caches the
  **target** only — judge/expansion (the paid OpenRouter calls) are not cached.

## Reading results

`mitre_stat.json` gives the per-category breakdown of benign vs. malicious-
compliant responses. As with the other tools, expect a bare 135M model to look
bad here — that's the finding. Report-only; it does not gate the pipeline.

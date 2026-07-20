# garak — LLM vulnerability scanning

Model-level adversarial safety probing for the vLLM-served model, run through
**NVIDIA NeMo Evaluator**. Part of the same "is this open-source model fit for
banking?" assessment as promptfoo — approached from the other side.

Companion to the other evaluation Jobs:

| What | Tool | Question it answers |
| --- | --- | --- |
| Quality | `lm-eval` | Does it get answers right? |
| Latency | `guidellm` | Is it fast enough? |
| Safety (banking behaviour) | `promptfoo` | Can it be made to give bad *financial* advice? |
| **Safety (model vulnerabilities)** | **garak** | **Can the model itself be jailbroken / hijacked / made toxic?** |

## garak vs promptfoo — why both

They answer different questions and grade differently, so they are not redundant.

| | promptfoo | garak |
| --- | --- | --- |
| Attacks | Banking-specific (invented rates, unlicensed advice, PII) | Generic model-level (jailbreaks, encoding bypass, prompt injection, malware, toxicity) |
| Grader | **LLM judge** (Haiku via OpenRouter) | garak's **own local detectors** — no external judge, no per-call cost |
| Corpus | Generated once, committed, replayed | Ships with garak; we pick which probes |
| Cost | Money per scan (judge calls) + traffic to a 3rd-party router | Compute only; probe traffic stays between CI and our router |

promptfoo tells you the model gives bad banking answers. garak tells you the
model can be *made to ignore its instructions entirely*. A bank needs both.

## What NeMo Evaluator actually does here

NeMo Evaluator is a thin wrapper. Given `--model_type chat` it selects garak's
`nim.NVOpenAIChat` generator, strips `/chat/completions` off the URL, writes a
`garak_config.yaml`, and runs plain `garak`. So this is a normal garak scan of an
OpenAI-compatible endpoint — the vLLM router — with NeMo standardising the config
and output shape (`results.yml`) to match the rest of the pipeline.

The router has no authentication, so NeMo exports a dummy `NIM_API_KEY` and vLLM
ignores the `Bearer` header. The only secret this job needs is `NCG_API_KEY` —
not to reach the model, but to pull the container image from NGC (see below).

## Files

| File | What it is |
| --- | --- |
| `run_config.yaml` | **The probe definition — which probes, how many samples, concurrency** |

The **target** (endpoint, model, model type) is *not* in this file — it is passed
by the workflow as CLI flags, which override config (NeMo precedence:
`CLI > run_config > task defaults > framework defaults`). This keeps the router
address in one place, the same way the `llmmap` job does, rather than duplicating
it across two files that must agree.

## Running it

In CI: the `garak` job in `.github/workflows/llmsecops.yml` (manual dispatch).
It runs NVIDIA's official eval-factory container, which has `nemo-evaluator` and
garak pre-installed:

```sh
# Pull requires an NGC account; username is the literal string $oauthtoken.
echo "$NCG_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
docker pull nvcr.io/nvidia/eval-factory/garak:latest

docker run --rm \
    -v "$PWD/run_config.yaml:/workspace/run_config.yaml:ro" \
    -v "$PWD/results:/workspace/results" \
    nvcr.io/nvidia/eval-factory/garak:latest \
    nemo-evaluator run_eval \
        --eval_type garak \
        --model_id HuggingFaceTB/SmolLM2-135M-Instruct \
        --model_type chat \
        --model_url http://136.116.192.130/v1/chat/completions \
        --run_config /workspace/run_config.yaml \
        --output_dir /workspace/results
```

Results (`results.yml` plus garak's `*.report.jsonl` / `*.report.html`) are
saved under `--output_dir` (bind-mounted out) and uploaded as the `garak-results`
artifact.

**Locally**, add `--dry_run` to the `run_eval` command to print the rendered
garak config without calling the model — the fastest way to check a
`run_config.yaml` edit.

### Container, and the `:latest` caveat

We run the official container (`nvcr.io/nvidia/eval-factory/garak`) rather than
the `nvidia-eval-factory-garak` pip wheel, so the whole toolchain — garak, its
detectors, the NeMo CLI — is the exact build NVIDIA ships, with nothing assembled
on the runner.

The job pulls **`:latest`**, which is *mutable*: two runs are not guaranteed to
use the same garak, and the image is deliberately **not** cached (a cache key that
never invalidates would pin a stale build — the same reason the promptfoo job only
caches because its tag is pinned). For a formal, reproducible assessment, pin a
dated tag (e.g. `:25.10`) in both the workflow and here.

**Setup:** add an `NGC_API_KEY` from [ngc.nvidia.com](https://ngc.nvidia.com) as
the repo/environment secret **`NCG_API_KEY`** (the name the workflow reads).
Without it the pull fails with an explicit error.

## Choosing probes

Everything is the `probes` line in `run_config.yaml` — a comma-separated list of
`module.ProbeClass`. `nemo-evaluator ls` lists the harness; `garak --list_probes`
lists every probe.

The committed set is chosen to **complement promptfoo**, not repeat it: jailbreaks
(`dan`, `grandma`), encoding bypass (`encoding`), prompt injection (`promptinject`,
`latentinjection`), malware generation (`malwaregen`), package hallucination, slurs
/ bullying (`lmrc`), unprompted toxicity (`realtoxicityprompts`), and confident
false assertions (`misleading`). None overlaps the `financial:*` plugins.

**Deliberately excluded:** NeMo's full default list is ~80 probes and includes
*adaptive* ones — `atkgen` (drives a red-team model), `tap`, `suffix.GCGCached` —
that are far too slow against a 135M model on CPU. Add those only when the model
is off CPU, and even then for a formal run, not the routine one.

`limit_samples` caps prompts **per probe**; several probes ship thousands. It is
the main runtime dial for a PoC baseline. Raise it (and `parallelism`) for the
formal assessment.

## Reading results

Expect this to be **substantially red**, for the same reason promptfoo is:
SmolLM2-135M has essentially no safety tuning and we run it bare, on purpose.
**That is the finding, not a bug.** A tiny base model with no guardrails will
jailbreak trivially — the report quantifies *how* trivially, which is exactly the
input the banking-fitness decision needs. Resist tuning the probe list until it
passes; the point is to measure the bare model, not to get a green check.

garak reports a **pass rate per probe** (fraction of attempts the detector judged
safe). Lower = more vulnerable. The `results.yml` NeMo writes is the diffable
summary; the `*.report.html` alongside it is the human-readable drill-down.

## Gating

**Report-only today**, like promptfoo — the job records results and uploads them
but does not fail the pipeline on a bad pass rate. Correct while establishing a
baseline: you cannot say which probe failures are unacceptable until you have seen
them. Once triaged, gate on a narrow, defensible set (e.g. `promptinject`,
`malwaregen`) rather than everything at once.

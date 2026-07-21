# Model LLMSecOps

An end-to-end **LLMSecOps** pipeline that answers one question:

> **Is a bare open-source language model fit for use in a retail bank?**

It provisions cloud infrastructure, serves an open model as an OpenAI-compatible
endpoint, and runs a battery of **safety, security, quality, and performance**
evaluations against it — then maps the findings to **NIST AI RMF** and **MITRE
ATLAS/ATT&CK** for a risk-committee-ready assessment.

> **Scenario (deliberate).** The model under test is
> **`HuggingFaceTB/SmolLM2-135M-Instruct`**, served **bare** on CPU — no system
> prompt, no guardrails, no filter, no tools, no retrieval. We assess the *raw
> model*, not a product. Expect the safety results to be substantially red: a
> tiny model with no safety tuning is *supposed* to fail here. **That is the
> finding, not a bug.** The small model is a deliberate latency-over-quality
> trade — the goal is to measure it and recommend an architecture, not to tune
> configs until it passes.

---

## What's in the box

| Layer | Tech | Purpose |
| --- | --- | --- |
| **Infrastructure** | Terraform → GKE, VPC, Artifact Registry, Storage, LB | Reproducible GCP cluster |
| **Serving** | vLLM (production-stack Helm chart), CPU | Model as an OpenAI-compatible endpoint |
| **Observability** | kube-prometheus-stack, Grafana, Pushgateway | Metrics + dashboards |
| **Quality** | `lm-eval` | Does it get answers right? |
| **Latency** | `guidellm` | Is it fast enough / how does it degrade? |
| **Safety & Security** | promptfoo, garak, CyberSecEval, LLMmap | Can it be made to do something harmful? |

## The security battery

Four complementary tools, run as a **serial chain** in one pipeline
(`.github/workflows/llmsecops.yml`) so they don't contend for the single-replica
CPU router:

```
promptfoo  →  llmmap  →  garak  →  cyberseceval
```

| Tool | What it tests | Grading | Framework mapping |
| --- | --- | --- | --- |
| **[promptfoo](security/promptfoo/)** | Banking-specific behaviour: invented rates, unlicensed advice, PII, bias | **LLM judge** (Claude Haiku via OpenRouter) | NIST Measure (Info Integrity, Harmful Bias, Privacy); ATLAS injection/jailbreak |
| **[garak](security/garak/)** | Generic model vulnerabilities: jailbreak, encoding bypass, prompt injection, malware, package hallucination | **Local detectors** (no judge) via NVIDIA NeMo Evaluator | NIST Measure 2.7 Security; ATLAS jailbreak/injection/leakage |
| **[CyberSecEval](security/cyberseceval/)** (Purple Llama) | Cyberattack compliance mapped to **MITRE ATT&CK** tactics | **LLM judge** (Claude Haiku) | NIST Security; **MITRE ATT&CK** |
| **[LLMmap](security/llmmap/)** | Model fingerprinting / provenance | Embedding distance to 52 reference models | NIST Map/Govern (provenance) |

Each tool has its own README with configuration, modules, and design notes.

## Repository layout

```
terraform/           GCP infrastructure (modular: gke, network, storage, artifact_registry, loadbalancer)
kubernetes/
  production-stack/  vLLM serving (values-cpu.yaml)
  observability/     Prometheus/Grafana, guidellm + lm-eval jobs, pushgateway
security/
  promptfoo/         Banking red-team (config + generated corpus)
  garak/             NeMo Evaluator vulnerability probes (run_config + site config)
  cyberseceval/      Purple Llama MITRE ATT&CK benchmark
  llmmap/            Model fingerprinting
reports/             Result artifacts + report-prompt.md (for generating the assessment report)
.github/workflows/   CI/CD pipelines
```

## Pipelines

| Workflow | Trigger | Does |
| --- | --- | --- |
| `infra-build.yml` | Manual / push to `terraform/**` | Provisions the GKE cluster and supporting GCP resources |
| `vllm-deploy.yml` | Manual / push to serving config | Helm-deploys the vLLM model server |
| `observability-deploy.yml` | Manual | Installs Prometheus/Grafana + eval jobs |
| `promptfoo-ui-deploy.yml` | Manual | Deploys the promptfoo results UI |
| `llmsecops.yml` | Manual | Runs the four-tool security battery |
| `infra-destroy.yml` | Manual (typed confirmation) | Tears the infrastructure down |

## Getting started

The pipeline is designed to be driven from CI (GitHub Actions), in order:

1. **Provision** — run *infra-build* (needs GCP credentials configured as repo secrets).
2. **Serve** — run *vllm-deploy* to bring up the model endpoint.
3. **Observe** — run *observability-deploy* for metrics + quality/latency jobs.
4. **Assess** — run *llmsecops* to execute the security battery; download the
   result artifacts.

### Secrets

| Secret | Used by |
| --- | --- |
| `OPENROUTER_API_KEY` | promptfoo & CyberSecEval judge (Claude Haiku) |
| `PROMPTFOO_API_KEY` | promptfoo red-team generation/grading |
| `NCG_API_KEY` | Pulling the garak eval-factory image from NGC |
| *(GCP credentials)* | Terraform + `kubectl`/Helm deploys |

## Reading the results

Result artifacts land in `reports/` (and as pipeline artifacts). To turn them
into a formal, framework-mapped assessment report, use
**[`reports/report-prompt.md`](reports/report-prompt.md)** — a ready-made prompt
that produces a risk-committee report from the tool outputs.

> **Note on sample sizes.** Some runs here are bounded *smoke tests* (e.g. garak
> capped to a handful of prompts) to keep CPU inference tractable. Treat those
> numbers as directional; re-run at full sample size for a formal assessment, and
> report rates with confidence intervals rather than single points.

## Key findings so far

- **Safety:** the bare model is trivially jailbroken, complies with cyberattack
  requests, and gives unlicensed financial advice — comprehensively unfit for
  direct customer-facing banking use *as a bare model*.
- **Performance / availability:** the serving tier is a **single CPU replica with
  no autoscaling** (~30 s/request), which cannot absorb concurrent load — a
  capacity risk independent of safety.
- **Recommendation direction:** *wrap, don't swap* — guardrails (input injection
  filtering, output moderation + PII redaction), constrained/retrieval-grounded
  generation, scope restriction, human-in-the-loop for anything transactional,
  and continuous CI re-assessment.

## Framework alignment

Findings are mapped to **NIST AI RMF** (Govern / Map / Measure / Manage) and the
**Generative AI Profile (AI 600-1)**, and to **MITRE ATLAS** (adversarial ML) and
**MITRE ATT&CK** (cyberattack tactics). This is a proof-of-concept assessment
harness; a formal sign-off additionally requires a validated LLM judge, full
sample sizes, and the governance controls noted in the tool READMEs.

# promptfoo — LLM red teaming

Adversarial safety testing for the vLLM-served model, as part of the assessment
of whether an open-source model is fit for banking use.

Companion to the other evaluation Jobs:

| What | Tool | Question it answers |
| --- | --- | --- |
| Quality | `lm-eval` | Does it get answers right? |
| Latency | `guidellm` | Is it fast enough? |
| **Safety** | **promptfoo** | **Can it be made to do something harmful?** |

## The three pieces

Most confusion about promptfoo comes from treating it as one thing. It is three,
and we run them in three different places:

| Piece | Command | Runs where | How often |
| --- | --- | --- | --- |
| **Generator** | `redteam generate` | Your laptop | Rarely, by hand |
| **Runner** | `redteam eval` | CI runner | Every pipeline run |
| **Server** | the container image | K8s Deployment | Always on |

The generator writes attack prompts. The runner fires them at the model and
grades the replies. The server stores and displays results.

**The server cannot run scans in a pipeline.** Its web UI can create evals
interactively, but there is no way for CI to drive it. That is why the scan is a
CLI run in the pipeline, and why it does not break when the UI is down.

### Why the scan runs on the CI runner, not in the cluster

Both the model router and the results UI are public LoadBalancers, so the runner
reaches them directly. Running the scan in-cluster would add a Job manifest, a
ConfigMap, a polling loop, and log-tailing to reach the same endpoints — cost
with no benefit. `kubectl` is used only to look up the two addresses.

This flips if you ever make those Services private. At that point the runner
cannot reach them and the scan has to move back into the cluster as a Job, or
onto a self-hosted runner inside the VPC. Worth remembering when the access
decision below gets revisited.

## The two pipelines

| Pipeline | File | Trigger | Does |
| --- | --- | --- | --- |
| **LLMSecOps** | `llmsecops.yml` | Manual | Runs the promptfoo scan and uploads the report |
| Promptfoo UI Deploy | `promptfoo-ui-deploy.yml` | Change to `values.yaml`, or manual | Helm-installs the results server |

The LLMSecOps pipeline has one job, `promptfoo`, which runs the scan and uploads
the report. Its steps:

1. Check the attack corpus is committed
2. Look up the model and UI addresses, and check both answer
3. Run the scan
4. Save `results.json` as a pipeline artifact
5. Upload the report to the UI

Promptfoo is one security check, not the whole pipeline — add further checks as
jobs alongside it. The name does not have to change when you do.

## Files

| File | What it is |
| --- | --- |
| `values.yaml` | Helm values for the results UI |
| `promptfooconfig.yaml` | **The scan definition — which attacks, which judge** |
| `generated/redteam.yaml` | The committed attack corpus (generated, not hand-written) |

## First-time setup

Three things must exist before the scan pipeline works.

**1. Generate and commit the attack corpus.** The pipeline replays a fixed corpus
and never generates, which keeps generation credentials out of CI and makes runs
comparable to each other.

```sh
cd kubernetes/promptfoo
promptfoo redteam generate -c promptfooconfig.yaml -o generated/redteam.yaml
git add generated/redteam.yaml && git commit -m "promptfoo: regenerate attack corpus"
```

Re-run this whenever you change `plugins`, `strategies`, `numTests`, or
`purpose` — the corpus is derived from all four. The scan pipeline fails with an
explicit error if the corpus is missing.

**2. Add the judge API key** as a GitHub repository secret named
`OPENROUTER_API_KEY`. See the Judge section below for why one is needed.

*Settings → Secrets and variables → Actions → New repository secret.*

**3. Deploy the UI** — run the *Promptfoo UI Deploy* pipeline. It prints the
address in the run summary.

## The judge (LLM-as-a-grader)

**We use an LLM judge, and it must be a stronger model than the one under test.**

Nearly every financial plugin is model-graded. "Did the model give unlicensed
investment advice?" or "did it invent a fee schedule?" cannot be checked with a
regex — something has to read the reply and decide. That something is the judge,
pinned in `promptfooconfig.yaml` under `defaultTest.options.provider`.

We judge through **OpenRouter on a cheap Haiku-class model**, pinned in
`promptfooconfig.yaml` under `defaultTest.options.provider`. Grading is a
classification task — "did this reply give investment advice?" — not a
generation task, so a small fast model does it well and a frontier model would
be wasted spend.

Two rules:

- **Never let SmolLM2 grade itself.** A 135M model cannot reliably detect its own
  compliance failures. Self-grading would turn this pipeline into theatre — it
  would report passes that are just the judge failing to notice. Any judge you
  pick must be clearly stronger than the model under test.
- **Pin the judge model and use `temperature: 0`.** If the grader drifts, scores
  move for reasons that have nothing to do with the model you are assessing, and
  historical comparisons in the UI become meaningless.

Why paid-but-cheap rather than a `:free` model: free tiers are aggressively
rate-limited, and one scan makes hundreds of grading calls. The scan runs with
`-j 2` for the same reason — each test case costs one call to the target *and*
one to the judge, so concurrency multiplies against the rate limit. Nothing is
lost by keeping it low; the target is a CPU-bound 135M model that was never
going to absorb parallelism.

Consequences to plan for: each scan costs money (roughly plugins × `numTests` ×
strategies calls), and prompts plus model responses go to a third-party router
to be graded. Check that against your data policy before this becomes routine —
the probes are synthetic, but the traffic is real.

**PoC caveat worth stating when you present results:** a cheap judge sets a
ceiling on how subtle a failure you can detect. It will reliably catch blatant
compliance failures and will be less consistent on borderline ones. That is an
acceptable trade for a baseline; it is not acceptable as the basis for signing
off a banking deployment. Upgrade the judge before results leave the team.

## Changing what you scan

Everything lives in the `redteam:` block of `promptfooconfig.yaml`. Two
independent dials:

- **Plugins = *what* to ask.** One plugin is one risk category.
- **Strategies = *how* to disguise it.** `basic` asks plainly; `base64` encodes
  it; `jailbreak` wraps it in a persona. Same attacks, different envelope.

The file has plugins grouped into commented tiers — uncomment to enable:

| Tier | When to turn it on |
| --- | --- |
| Core | On now. Fits a bare model aimed at retail banking. |
| Enable when the model gains context | Once you add RAG, tools, or a system prompt — leakage tests need something to leak. |
| Enable by business context | Market commentary, naming real firms, SOX reporting, Japan operations. |
| Enable when it becomes a product | `contracts`, `imitation`, `excessive-agency` — needs a persona and real capabilities. |
| Compliance mapping | `owasp:llm`, `nist:ai:measure` for the formal assessment run. Slow; not nightly. |

**After any change, regenerate the corpus** (step 1 above) or the scan will keep
replaying the old attacks.

### The rule that matters most

Only enable plugins for surface you actually have. We deliberately skip `bola`,
`bfla`, `rbac`, `sql-injection`, and `shell-injection` — this model has no
authorization, no database, and no shell, so those would generate failures
describing risks that do not exist. A report full of irrelevant findings is how
a team learns to ignore the report.

## Reading results

Open the UI address from the *Promptfoo UI Deploy* run summary. Each scan
appears as a run you can diff against previous ones — which is the whole point of
a fixed corpus.

Expect the first scan to be substantially red. SmolLM2-135M has no safety tuning
to speak of, and this assessment deliberately runs it bare. **That is a finding,
not a bug.** The question this pipeline answers is "is this model fit for
banking?", and a wall of red is a legitimate answer to that question. Resist the
pull to tune the config until it passes.

## Turning on gating

The scan is **report-only** today: the *Run scan* step records the exit status
but does not act on it, so failed probes never fail the pipeline. Correct while
you are establishing a baseline — you cannot say which failures matter until you
have seen them.

Once you have triaged the baseline, add a step after the upload that fails when
`steps.scan.outputs.status` is non-zero. Gate on a narrow, defensible set first
(`pii:direct` is the usual choice for a bank) rather than everything at once.

Note this applies to failed **probes** only. A failed **upload** already fails
the pipeline — a model failing a probe is a finding, but results that never
reached the UI are a broken pipeline.

## Access decision

The results UI is deployed as a **public, unauthenticated LoadBalancer**
(`values.yaml`, `service.type`). This is a deliberate choice, recorded here.

What it means: promptfoo self-hosted ships with no authentication or SSO, so
anyone who reaches the address can read the findings — which are a catalogue of
the attacks that currently work against the model. The UI can also launch evals
against the target when API keys are present. This matches the existing posture
of the vLLM router, which is also a public unauthenticated LoadBalancer
(`production-stack/values-cpu.yaml`).

Accepted for the assessment phase, when the cluster holds no customer data and
no production traffic. **Revisit before this model carries real traffic** — at
that point the findings become genuinely sensitive. The upgrade path is a GKE
Ingress behind Identity-Aware Proxy, which keeps the public URL and adds Google
sign-in with per-user IAM control; only `service.type` and an Ingress change.

The UI deploy pipeline reports exposure in its run summary on every run rather
than blocking, following the same pattern as `vllm-deploy.yml`.

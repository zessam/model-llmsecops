# Observability & Evaluation

| Source | Measures | Reaches Grafana via |
|---|---|---|
| vLLM engine `/metrics` | tokens/s, TTFT, e2e latency, queue, cache | Prometheus scrapes (ServiceMonitor) |
| router `/metrics` | request counts, routing, per-backend stats | Prometheus scrapes (ServiceMonitor) |
| **lm-eval** | quality — accuracy on tasks (gsm8k) | pushes `lm_eval_score` → Pushgateway |
| **GuideLLM** | performance under controlled load | pushes `guidellm_metric` → Pushgateway, plus live serving metrics |

```
engine /metrics ─┐
router /metrics ─┼─▶ Prometheus ─▶ Grafana (public LoadBalancer)
Pushgateway ─────┘        ▲
lm-eval  ── push scores ──┤
GuideLLM ── push report ──┘ (and drives load, visible in serving panels)
```

## Deploy

Via the pipeline: **Actions → Observability Deploy → Run workflow**, pick `deploy`,
then approve on the `production` environment. The `action` dropdown also offers
`run-eval` (re-runs both Jobs) and `uninstall`.

Manual equivalent:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --version 87.17.0 -n monitoring --create-namespace \
  -f kubernetes/observability/kube-prom-stack-values.yaml
kubectl apply -f kubernetes/observability/pushgateway.yaml
kubectl apply -f kubernetes/observability/dashboard.yaml
```

Run the evaluations **after** vLLM is serving:

```bash
kubectl apply -f kubernetes/observability/lm-eval-job.yaml
kubectl apply -f kubernetes/observability/guidellm-job.yaml
kubectl logs -f job/lm-eval-gsm8k
```

## Reaching Grafana

```bash
kubectl get svc kube-prom-stack-grafana -n monitoring   # wait for EXTERNAL-IP
kubectl get secret kube-prom-stack-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

User `admin`. Open `http://<EXTERNAL-IP>` → dashboard **LLM Quality & Performance**.

## Requirements that are easy to miss

- `values-cpu.yaml` must set `serviceMonitor.enabled: true` on **both**
  `servingEngineSpec` and `routerSpec`. The chart defaults them to `false`, and
  without them Prometheus scrapes no vLLM metrics at all.
- The eval Jobs target `HuggingFaceTB/SmolLM2-135M-Instruct`. If the model changes in
  `values-cpu.yaml`, update `lm-eval-job.yaml` too or lm-eval gets a 404.
- Jobs are immutable — `kubectl delete job` before re-applying.
- `--limit 5` on lm-eval is deliberate. CPU inference is slow; a full gsm8k run
  takes hours. These numbers show the pipeline works, not real model quality.

## Security

Grafana is a public LoadBalancer with a generated admin password. The Pushgateway
is **ClusterIP with no auth** — anything in the cluster can write arbitrary
metrics to it, so it must not be exposed. The eval Jobs `pip install` at runtime,
which Checkov flags; pinned images would be the hardened form.

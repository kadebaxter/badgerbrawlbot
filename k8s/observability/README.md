# Watching the swarm in Grafana

Every swarm pod serves `/metrics` (port 9568, see `lib/swarm/metrics.ex`) and logs each decision
with its reason as a `decision kind=… tick=… msg="…"` line (`lib/swarm/decisions.ex`).
kube-prometheus-stack (the `monitoring` release) scrapes the metrics; Loki stores the logs,
which Alloy collects.

## Once

```bash
cd k8s/observability

# Metrics: scrape the swarm pods. (The StatefulSet must have the metrics port: re-apply it too.)
kubectl apply -f ../statefulset.yaml -f podmonitor.yaml

# Logs: Loki to store them, Alloy to collect them, and Loki as a Grafana datasource.
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm install loki  grafana/loki  -n monitoring -f loki-values.yaml
helm install alloy grafana/alloy -n monitoring -f alloy-values.yaml
kubectl apply -f loki-datasource.yaml

# The dashboard.
kubectl apply -f dashboard.yaml
```

Grafana picks up the datasource and dashboard by itself; if Loki doesn't show up under
Connections > Data sources within a minute, restart Grafana:
`kubectl -n monitoring rollout restart deployment monitoring-grafana`.

## Checking each piece

```bash
# Prometheus is scraping the pods: all three "up" (Prometheus UI > Status > Targets, or)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090 &
curl -s 'localhost:9090/api/v1/query?query=up{namespace="netrts"}' ; kill %1

# One pod's metrics, straight from the source:
kubectl -n netrts port-forward pod/swarm-0 9568 &
curl -s localhost:9568/metrics | head -20 ; kill %1

# Loki and Alloy are running:
kubectl -n monitoring get pods -l 'app.kubernetes.io/name in (loki,alloy)'
```

In Grafana: Dashboards > NetRTS Swarm. Explore > Loki with
`{namespace="netrts"} |= "decision" | logfmt` shows the decision log on its own.

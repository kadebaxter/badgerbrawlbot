# Deploying to k3s

GitHub Actions builds the image and pushes it to GHCR (`.github/workflows/ci.yml`); nothing on
GitHub talks to the cluster. You deploy from your machine with `kubectl`.

## Once

```bash
kubectl apply -f k8s/namespace.yaml

# The API key and the Erlang cookie. Never in the repo or the image.
kubectl -n netrts create secret generic swarm \
  --from-literal=api-key="$NETRTS_API_KEY" \
  --from-literal=cookie="$(openssl rand -hex 32)"

# Lets the cluster pull the private image: a GitHub token with read:packages.
kubectl -n netrts create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=<github user> --docker-password=<token>

kubectl apply -f k8s/service.yaml -f k8s/statefulset.yaml
```

## Each deploy

Push to `main`, wait for the CI run, then deploy the commit's image (tagged `sha-<short sha>`):

```bash
kubectl -n netrts set image statefulset/swarm swarm=ghcr.io/kadebaxter/badgerbrawlbot:sha-$(git rev-parse --short HEAD)
kubectl -n netrts rollout status statefulset/swarm
```

The pods restart one at a time, so two of three stay up and the swarm keeps its leader. A heat in
progress carries on (ra keeps its state on each pod's volume).

## Watching and playing

```bash
kubectl -n netrts get pods -o wide           # which machine each node is on
kubectl -n netrts logs -f swarm-0            # one node's log
kubectl -n netrts exec -it swarm-0 -- bin/swarm remote
```

`bin/swarm remote` is an `iex` on that node, inside the cluster: `Swarm.status()`,
`Swarm.play(opponents: ["rusher"])`, `Swarm.join("season-week3")`, `Swarm.enemies()`.

## Starting over

`kubectl -n netrts delete statefulset swarm` keeps the volumes (and so the ra state). To wipe it
too: `kubectl -n netrts delete pvc data-swarm-0 data-swarm-1 data-swarm-2`.

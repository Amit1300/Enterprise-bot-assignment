# Enterprise Bot — DevOps Assignment

| Part | Where |
|---|---|
| 1 — service and Dockerfile | `service/` |
| 2 — Helm chart | `chart/` |
| 3 — one-command setup | `setup.sh` |
| 4 — debug lab | `lab/` (fixes in `lab/broken-chart/`, write-up in `lab/FINDINGS.md`) |
| 5 — written answer | `ANSWERS.md` |
| Bonus — CI | `.github/workflows/ci.yml` |

## Run

Needs Docker, kind, kubectl and helm. Ports 80 and 443 must be free.

```bash
./setup.sh          # create cluster, install ingress-nginx, build image, deploy chart
./setup.sh delete   # delete the cluster and the local images
```

`setup.sh` can be run again safely.

## Verify

```bash
kubectl -n demo get pods,svc,ingress

curl -H "Host: demo.local" http://localhost/
curl -H "Host: demo.local" http://localhost/healthz
```

Change the config without redeploying (takes up to ~1 minute to show up):

```bash
kubectl -n demo patch configmap demo --type merge -p '{"data":{"APP_NAME":"changed"}}'
curl -H "Host: demo.local" http://localhost/
```

Check chart overrides:

```bash
helm template demo chart --set replicaCount=3 --set config.appName=foo | grep -E 'replicas|APP_NAME'
```

Part 4 lab:

```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

## Resource requests and limits

| | Request | Limit |
|---|---|---|
| CPU | 50m | 250m |
| Memory | 64Mi | 128Mi |

Why these numbers:

- **Memory request 64Mi.** The app runs gunicorn with 2 workers. When I
  tested it under load it used about 56–58Mi. So 64Mi is what the pod really
  needs.
- **Memory limit 128Mi.** Double the request. It gives room for a spike, and
  if there is a memory leak the pod is killed and restarted before it hurts
  the node.
- **CPU request 50m.** The app does very little work per request and is idle
  most of the time, so a small request is enough.
- **CPU limit 250m.** Enough for start-up and short bursts, but one pod
  cannot take the whole CPU of a small kind node.

I got these numbers from one short local test, not from real traffic. In
production I would look at real usage for some days and then change them.

## What I skipped, and the risk

| Skipped | Risk |
|---|---|
| TLS on the Ingress | Traffic is not encrypted. |
| `/etc/hosts` entry for `demo.local` | You have to use `-H "Host: demo.local"`. I did not want the script to need sudo. |
| HorizontalPodAutoscaler | Always 2 replicas; it cannot scale with load. |
| PodDisruptionBudget | A node drain can take both pods down together. |
| NetworkPolicy | Any pod in the cluster can call the service. |
| `preStop` sleep / graceful drain | A request can fail during a rolling update. |
| Base image pinned by tag, not digest | The tag could be pushed again with different content. |
| Fixing the image scan findings | The Trivy step in CI fails right now (see CI section). |
| Image registry | The image is loaded directly into kind and not pushed anywhere. |

## What I would change for production

- TLS with cert-manager, and move from ingress-nginx (end-of-life) to
  Gateway API — see `ANSWERS.md`.
- Push images to a registry, pin base images by digest, deploy by digest.
- A smaller base image (distroless or similar) to reduce CVEs, and rebuild
  it on a schedule so fixes come in.
- HPA, PodDisruptionBudget, spread pods over nodes, and a `preStop` hook so
  a rolling update drops no requests.
- NetworkPolicy, `capabilities: drop: [ALL]` and a seccomp profile.
- Metrics, structured logs and alerts.
- Deploy with CI/CD (GitOps) instead of a shell script.

## Part 4 status

`./scenario.sh verify` is at **7 of 11**. It is not all green.

I fixed 7 problems in the chart: Job `restartPolicy`, missing numeric
`runAsUser`, wrong container port, gateway `BACKEND_URL` namespace, reporter
RoleBinding subject, worker cache volume, and metrics CPU above the
LimitRange.

The 4 checks still failing all come from the reporter. After the RBAC fix it
is allowed to list pods, but it logs
`parse pod list: unexpected end of JSON input` and never becomes Ready. From
what I can see the app reads only the first 1 KB of the API answer, and the
real pod list is much bigger. I found nothing in the chart that changes this.
I did not remove the readiness probe or disable the reporter to hide it.
`verify` also shows FAIL for backend and gateway, but both are Ready and
working. Details and output are in `lab/FINDINGS.md`.

## CI (bonus)

`.github/workflows/ci.yml` runs on every push and pull request:

1. `helm lint chart --strict`, and a render with overrides.
2. `docker build` of `service/`.
3. Trivy scan of the image. It fails on HIGH or CRITICAL.

**The Trivy step fails right now.** I left it like this and did not weaken
the check. A local scan with Trivy 0.68.1 gave 51 HIGH and 0 CRITICAL. All
of them are in Debian packages from the `python:3.12-slim` base image, none
in Flask or gunicorn. 44 have no fix yet. 7 (OpenSSL and PCRE2) would be
fixed by rebuilding on a newer base image. The real fix is a smaller base
image, which is in my production list above.

## How I used AI

I used **Claude Code** (AI assistant in the terminal) in this assignment.

- **Parts 1–3:** I used it to help write and simplify the service, the
  Dockerfile, the chart and `setup.sh`. I ran and tested them myself.
- **Part 4:** I did the debugging in my own cluster. I used Claude to help
  me debug: to get the right commands, to get hints on where to look, to
  explain output I did not understand, and to check my fixes.
- **Parts 5 and 6, the CI workflow and the wording of `FINDINGS.md`:** I
  used it to help write and clean up the text, and I checked it against my
  own session.

What I had to correct or watch:

- It first installed the lab into the wrong kind cluster. I had it delete
  that cluster and make a clean one.
- My first recording attempts were broken (nested `script` sessions, and the
  log got printed into itself). That is why the start of
  `part4-session.log` repeats.
- For the port defect it first suggested an env var in five templates. I
  asked for a change only in `values.yaml` and used that.

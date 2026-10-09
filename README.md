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

- **Memory request 64Mi.** The container runs gunicorn with two workers. I
  measured about 56–58Mi in use under load, so 64Mi is what the pod really
  needs and what the scheduler should reserve.
- **Memory limit 128Mi.** Twice the request. It leaves room for spikes, and a
  leak gets the pod OOM-killed and restarted before it can hurt the node.
- **CPU request 50m.** The service does almost no work per request, so it is
  idle most of the time. A small request keeps it cheap to schedule.
- **CPU limit 250m.** Enough for short bursts and for start-up, low enough
  that one pod cannot starve its neighbours on a small kind node.

These numbers come from one short local test, not from real traffic. In
production I would set them from observed usage over days and revisit them.

## What I deliberately skipped, and the risk

| Skipped | Risk |
|---|---|
| TLS on the Ingress | Traffic is unencrypted. |
| `/etc/hosts` entry for `demo.local` | You must pass `-H "Host: demo.local"`. I avoided needing sudo. |
| HorizontalPodAutoscaler | Fixed at two replicas; no scaling under load. |
| PodDisruptionBudget | A node drain could take both pods down at once. |
| NetworkPolicy | Any pod in the cluster can reach the service. |
| `preStop` sleep / graceful drain | A request can fail during a rolling update. |
| Image pinned by tag, not digest | The base tag could be re-pushed with different content. |
| Fixing the image scan findings | See the CI section: the Trivy step currently fails. |
| Image registry | The image is loaded straight into kind; nothing is pushed anywhere. |

## What I would change for production

- TLS with cert-manager, and move from ingress-nginx (end-of-life) to the
  Gateway API — see `ANSWERS.md`.
- Push images to a registry, pin base images by digest, and deploy by digest.
- A smaller base image (distroless or similar) to cut the CVE count, with
  scheduled rebuilds so fixes are picked up.
- HPA, PodDisruptionBudget, topology spread across nodes, and a `preStop`
  hook so rolling updates drop no requests.
- NetworkPolicy, `capabilities: drop: [ALL]` and a seccomp profile.
- Metrics, structured logs and alerts; resource numbers based on real usage.
- Deploy through CI/CD (GitOps) instead of a shell script.

## Part 4 status

`./scenario.sh verify` is at **7 of 11**, not all green.

I fixed seven chart defects (Job `restartPolicy`, missing numeric `runAsUser`,
container port, gateway `BACKEND_URL` namespace, reporter RoleBinding subject,
worker cache volume, metrics CPU over the LimitRange).

The four remaining failures all come from the reporter. After the RBAC fix it
is allowed to list pods, but it logs
`parse pod list: unexpected end of JSON input` and never becomes Ready. The
application appears to read only the first 1 KB of the API response, and the
real pod list is far larger. I found no chart setting that changes this, and I
did not remove the readiness probe or disable the workload to hide it. The
`backend` and `gateway` checks also report FAIL in `verify`, but both answer
correctly when probed directly. Details and evidence are in `lab/FINDINGS.md`.

## CI (bonus)

`.github/workflows/ci.yml` runs on every push and pull request:

1. `helm lint chart --strict`, plus a render with overrides.
2. `docker build` of `service/`.
3. Trivy scan of the image, failing on HIGH or CRITICAL findings.

**The Trivy step currently fails**, and I left it that way rather than weaken
the gate. Scanning the image locally with Trivy 0.68.1 gave 51 HIGH and 0
CRITICAL findings, all in Debian packages from the `python:3.12-slim` base
image and none in the Python dependencies. 44 have no fix available yet; 7
(OpenSSL and PCRE2) are fixable by rebuilding on an updated base image. The
real fix is a smaller base image, listed above.

## How I used AI

I used **Claude Code** (Anthropic's CLI assistant) throughout.

- **Parts 1–3:** Claude helped write and simplify the service, Dockerfile,
  chart and `setup.sh`. I ran and tested them myself.
- **Part 4:** I ran the commands in my own cluster and applied the fixes.
  Claude explained the output and, after the first defect, identified most of
  the causes and proposed the fixes. It also analysed the lab image to find
  why the reporter still fails.
- **Parts 5 and 6 and the CI workflow:** drafted by Claude, reviewed by me.

What I had to correct or watch for:

- Claude first installed the lab into the wrong kind cluster; I had it
  recreate a clean cluster.
- My first session recording was unusable (nested `script` sessions, and the
  log was printed into itself), which Claude spotted.
- Claude's first suggestion for the port defect was an env var in five
  templates; I chose a single change in `values.yaml` instead.

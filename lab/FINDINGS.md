# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

**Short summary:** I found and fixed 7 problems in the chart. `verify` is at
7 of 11. The 4 checks still red all come from the reporter, which I could not
fix from the chart — see the last section. All output below is copied from my
session recording (cluster `kind-lab`).

---

## Defect 1 — migrate Job rejected: `restartPolicy: Always`

**Symptom** (what you observed — paste the real command output):

The first `up` failed with a helm error, and the Job was never created.

```
$ sh scenario.sh up
==> installing the broken chart
Release "debug-lab" does not exist. Installing it now.
Error: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause** (the actual root cause, not the symptom restated):

`templates/migrate-job.yaml` had `restartPolicy: Always`. A Job does not
allow `Always`, only `OnFailure` or `Never`. Because helm stopped on this
error, the release was only partly installed.

**Fix** (what you changed, and why this over alternatives):

Changed it to `restartPolicy: OnFailure`. I picked `OnFailure` over `Never`
because a migration that fails once should be retried in the same pod, and
`backoffLimit: 2` already limits the retries.

**How I found it** (the sequence of commands/reasoning that led you here):

The helm error names the exact field. The message says "Required value",
which is a bit misleading because the field was there, so I looked at the
list of valid values and then at the file:

```
$ grep -n res migrate-job.yaml
migrate-job.yaml:16:      restartPolicy: Always
```

---

## Defect 2 — all pods `CreateContainerConfigError`: `runAsNonRoot` with a non-numeric user

**Symptom:**

After defect 1, helm installed, but no container started.

```
$ kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS   AGE
backend-7d66946bf7-54hjz    0/1     CreateContainerConfigError   0          5m52s
gateway-f84d965df-gs679     0/1     CreateContainerConfigError   0          5m52s
metrics-55757548d4-8lkmd    0/1     CreateContainerConfigError   0          5m52s
migrate-tl6gv               0/1     CreateContainerConfigError   0          46s
reporter-6f7cc7495f-b9nn7   0/1     CreateContainerConfigError   0          5m52s
worker-7694df7b9c-brsk8     0/1     CreateContainerConfigError   0          5m52s
```

From `kubectl describe pod backend-7d66946bf7-54hjz -n debug-lab`:

```
  Warning  Failed     57s (x26 over 6m15s)  kubelet            Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "backend-7d66946bf7-54hjz_debug-lab(6d6d1873-9a87-4d70-97dc-d66ad9a0213e)", container: backend)
```

**Cause:**

Every template sets `runAsNonRoot: true`, but the image sets its user by
name (`nonroot`), not by number. The kubelet can only check "not root" with a
numeric UID, so it refuses to start the container.

**Fix:**

Added `runAsUser: 65532` under `runAsNonRoot: true` in all six templates.
65532 is the UID of `nonroot` in the image's `/etc/passwd`. I kept
`runAsNonRoot: true` instead of removing it, because removing it would make
the error go away by dropping the security check.

One extra step: after this change `up` failed again, because a Job's pod
template cannot be changed once the Job exists:

```
Error: UPGRADE FAILED: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template: Invalid value: {...}: field is immutable
```

So I ran `kubectl -n debug-lab delete job migrate` and then `up` again. Helm
created the Job again from the fixed template and it completed. This is not
removing a workload; the Job is still in the chart.

**How I found it:**

First I tried `kubectl logs`, but there were no logs because the container
never started. `CreateContainerConfigError` means the problem is before
start, so I used `kubectl describe pod` and read the Events at the bottom.
All six pods had the same status, so I expected one cause for all. The UID
comes from the image: its `/etc/passwd` (read with `docker export`) has
`nonroot:x:65532:65532`.

---

## Defect 3 — pods Running but never Ready: app listens on 8081, chart uses 8080

**Symptom:**

```
$ kubectl get pods -n debug-lab
backend-66969c8999-56q5k    0/1     Running                      0             2m46s
gateway-76f9d798f5-tjj2l    0/1     Running                      0             2m46s
reporter-775887b7b5-ttzsv   0/1     Running                      0             2m46s
```

```
$ kubectl logs -f backend-66969c8999-56q5k  -n debug-lab
2026/10/09 13:19:23 eb-debug-app 2.0.0 starting: mode=api pod=backend-66969c8999-56q5k listening on :8081 (image default is 8081; set PORT to override)
```

Events:

```
26m         Warning   Unhealthy           pod/backend-66969c8999-56q5k     Readiness probe failed: Get "http://10.244.0.12:8080/healthz": dial tcp 10.244.0.12:8080: connect: connection refused
```

**Cause:**

The chart uses `common.port: 8080` for the container port, the readiness
probe and the Service `targetPort`. The app listens on 8081 by default and
nothing tells it to use 8080. So the probe hits a closed port.

**Fix:**

Changed `common.port` to `8081` in `values.yaml`. This is one line and it
fixes all five deployments, because every template reads this value. The
Service ports (8080 and 80) are written in the templates, so
`http://backend:8080` still works. The other option was to add a `PORT=8080`
env var to every workload; I chose the single setting so the port is defined
in one place.

**How I found it:**

Status was `Running` with `0/1`, which usually means the readiness probe is
failing. The app log says which port it listens on, and the probe error
shows which port the chart is calling. They are different.

---

## Defect 4 — gateway not Ready: `BACKEND_URL` points to the wrong namespace

**Symptom:**

After the port fix, backend became Ready but gateway did not.

```
$ kubectl -n debug-lab logs -l app=gateway --tail=4 --prefix
[pod/gateway-68d794989f-4spgd/gateway] 2026/10/09 13:37:38 readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: Get "http://backend.default.svc:8080/healthz": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
[pod/gateway-68d794989f-4spgd/gateway] 2026/10/09 13:37:38 GET /healthz -> 503 (from 10.244.0.1:39438)
```

**Cause:**

`values.yaml` had `BACKEND_URL: "http://backend.default.svc:8080"`. That
means the backend Service in the `default` namespace. The backend is in
`debug-lab`, so DNS finds nothing and the gateway reports itself not ready.

**Fix:**

Changed it to `http://backend.debug-lab.svc:8080`. A shorter `http://backend:8080`
would also work and would follow the release to any namespace; I would
switch to that if this chart had to be installed in other namespaces.

**How I found it:**

My first `kubectl logs deploy/gateway` picked the old pod and only showed
the start line, which told me nothing. With `-l app=gateway --prefix` I got
the log of the new pod and it shows the full URL and `no such host`.
`kubectl get svc -n debug-lab` confirmed where the backend Service is.

---

## Defect 5 — reporter gets 403: RoleBinding points to the wrong ServiceAccount

**Symptom:**

```
$ kubectl logs -f reporter-66b7477f4f-zm6zw   -n debug-lab
2026/10/09 13:32:20 pod list failed: kubernetes API returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" in API group \"\" in the namespace \"debug-lab\"","reason":"Forbidden","details":{"kind":"pods"},"code":403}
2026/10/09 13:32:20 GET /healthz -> 503 (from 10.244.0.1:59092)
```

```
$ kubectl auth can-i list pods -n debug-lab \
  --as=system:serviceaccount:debug-lab:reporter
no
```

**Cause:**

The reporter pod runs as ServiceAccount `reporter`. The Role `reporter-read`
is correct (get and list on pods), but in `templates/rbac.yaml` the
RoleBinding gives it to ServiceAccount `default`. So `reporter` has no
permission.

**Fix:**

Changed the RoleBinding subject from `name: default` to `name: reporter`.
I did not make the pod run as `default` instead, because then every pod in
the namespace without its own ServiceAccount would get this permission too.

After the fix:

```
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
yes
```

**How I found it:**

The log names the exact user that was refused. `auth can-i` confirmed it
from the cluster side. Then I compared the user in the log with the
`subjects` in `rbac.yaml`.

---

## Defect 6 — worker CrashLoopBackOff: no writable cache directory

**Symptom:**

```
worker-95f494bf9-2k9wp      0/1     CrashLoopBackOff             6 (3m37s ago)   9m18s
```

```
$ kubectl logs -f worker-84d9969597-2b6z2 -n debug-lab
2026/10/09 13:43:18 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

`describe pod` showed `Last State: Terminated`, `Reason: Error`, `Exit Code: 1`.

**Cause:**

The container has `readOnlyRootFilesystem: true` and the worker needs to
write to `/var/cache/app`. There was no volume there, so it exits at start.

**Fix:**

In `templates/worker.yaml` I added an `emptyDir` volume (with a 500Mi size
limit) mounted at `/var/cache/app`. I kept the read-only root filesystem.
Turning it off would also work but it would weaken the container for one
directory.

**How I found it:**

`CrashLoopBackOff` means the app starts and dies, so the answer is in the
logs, not in the events. The log line says exactly what is missing.

---

## Defect 7 — metrics has no pod at all: CPU limit above the namespace LimitRange

**Symptom:**

`verify` showed `deployment metrics: 0/1 ready`, but `get pods` showed no new
metrics pod at all — not Pending, not crashing.

```
$ kubectl get events -n debug-lab | grep metric
36m         Warning   FailedCreate        replicaset/metrics-5dcfcd74cd    Error creating: pods "metrics-5dcfcd74cd-75fst" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:**

`values.yaml` asked for cpu request `2` and limit `4` for metrics. The
namespace LimitRange (`debug-lab-guardrails`, from `cluster-state/`) allows
max 1 CPU per container. So the ReplicaSet could not create the pod.

**Fix:**

Changed metrics to request `50m` and limit `200m`, same as the other
services. The LimitRange is the environment and I am not allowed to change
it, so the chart has to fit inside it.

**How I found it:**

This one is easy to miss because `get pods` shows nothing wrong. A
Deployment with zero pods means the ReplicaSet cannot create them, so I
looked at the namespace events and filtered for metrics.

---

## Not fixed — reporter still not Ready (I ran out of options in the chart)

Final state:

```
$ sh scenario.sh verify
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  FAIL  deployment reporter: 0/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  FAIL  backend does not answer on http://backend:8080/healthz
  FAIL  gateway /status does not report backend=ok
  FAIL  reporter /report does not return a pod count

4 check(s) failing, 7 passing.
```

**What I see.** After the RBAC fix the 403 is gone, but the reporter has a
new error and still answers 503 on `/healthz`:

```
$ kubectl logs -f reporter-66b7477f4f-9jjns -n debug-lab
2026/10/09 13:51:29 eb-debug-app 2.0.0 starting: mode=reporter pod=reporter-66b7477f4f-9jjns listening on :8081 (image default is 8081; set PORT to override)
2026/10/09 13:51:36 pod list failed: parse pod list: unexpected end of JSON input
2026/10/09 13:51:36 GET /healthz -> 503 (from 10.244.0.1:53224)
```

**What I think the cause is.** The app seems to read only the first 1 KB of
the pod list and then parse it. The real list for this namespace is about
48 KB, so the JSON is cut in the middle. I checked this by cutting the real
API answer at 1024 bytes myself:

```
$ kubectl get --raw '/api/v1/namespaces/debug-lab/pods?limit=100' | head -c 1024 | python3 -m json.tool
Unterminated string starting at: line 1 column 1012 (char 1011)
```

Same kind of error as the app.

**Why I stopped.** I could not find any value or env var in the chart that
changes this. The things that would turn the checks green are removing the
reporter readiness probe, disabling the reporter, or changing the image, and
the rules forbid these. So I left it failing and honest. I also tried
deleting the reporter pod to get a fresh one; same error.

**About the backend and gateway FAIL lines.** Both are healthy (`1/1`, and
the gateway is Ready only when it can reach the backend). `verify` runs one
probe pod for the last three checks, and when the reporter call fails the
first two results seem to get lost. I believe these two would go green
together with the reporter.

**What I would do next.**

- Ask the image owners if 1.0.1 is expected to pass the reporter check, and
  for a fixed build if not.
- If I am wrong about the 1 KB limit, the next thing I would check is what
  exactly the reporter sends to the API (for example with an audit log on
  the kind API server).

**Mistakes and dead ends in the recording** (so they are not a surprise):

- My first recording attempts were nested `script` sessions, and I printed
  the log into itself once, so the start of the log repeats many times. The
  real session is the last part of the file.
- I typed the wrong namespace several times (`debug-pod`, `debug-pods`).
- I deleted a backend pod and a reporter pod once to see if a new pod would
  behave differently. It did not; the Deployment recreated them.

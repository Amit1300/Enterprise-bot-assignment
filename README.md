# Enterprise Bot — DevOps take-home

## Run it

Prerequisites: Docker, kind, kubectl, helm (v3 or v4). Host ports 80/443 must be free.

```bash
./setup.sh      # creates kind cluster "demo", installs ingress-nginx, builds + loads
                # the image, installs release "demo" into namespace "demo".
                # Idempotent: safe to run again.
```

## Verify

```bash
kubectl -n demo get pods,svc,ingress            # 2/2 pods Running and Ready

# Through the Ingress (no /etc/hosts edit needed):
curl -H "Host: demo.local" http://localhost/
# {"app":"demo","pod":"demo-demo-<hash>","version":"0.1.0"}
curl -i -H "Host: demo.local" http://localhost/healthz    # HTTP 200

# Config changes are picked up without a restart (within ~60-90s, kubelet sync):
kubectl -n demo patch configmap demo-demo --type merge -p '{"data":{"APP_NAME":"changed"}}'
curl -H "Host: demo.local" http://localhost/

# Chart overrides:
helm template demo ./chart --set replicaCount=3 --set config.appName=foo | grep -E 'replicas|APP_NAME'
```

Optionally add `127.0.0.1 demo.local` to `/etc/hosts` and use `curl http://demo.local/`.

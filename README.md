# Enterprise Bot — DevOps Assignment

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

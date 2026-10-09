#!/usr/bin/env bash
set -euo pipefail

CLUSTER=demo
NAMESPACE=demo
RELEASE=demo
IMAGE=demo-service
INGRESS_URL=https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml

cd "$(dirname "$0")"

if [ "${1:-}" = "delete" ]; then
  kind delete cluster --name "$CLUSTER"
  docker rmi -f $(docker images -q "$IMAGE") 2>/dev/null || true
  exit 0
fi

for tool in docker kind kubectl helm curl; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed"; exit 1; }
done

echo "==> kind cluster"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  cat <<YAML | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443
YAML
fi
kubectl config use-context "kind-$CLUSTER"

echo "==> ingress-nginx"
kubectl apply -f "$INGRESS_URL"
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

echo "==> build image"
TAG=$(find service -type f | sort | xargs sha256sum | sha256sum | cut -c1-12)
docker build -t "$IMAGE:$TAG" service
kind load docker-image "$IMAGE:$TAG" --name "$CLUSTER"

echo "==> helm install"
FORCE=""
if helm version --short | grep -q '^v4'; then
  FORCE="--force-conflicts"
fi
for i in 1 2 3 4 5; do
  helm upgrade --install "$RELEASE" chart -n "$NAMESPACE" --create-namespace \
    --set image.tag="$TAG" $FORCE --wait --timeout 180s && break
  [ "$i" = 5 ] && exit 1
  sleep 10
done

echo "==> waiting for ingress"
for i in $(seq 30); do
  curl -sf -H "Host: demo.local" http://localhost/healthz >/dev/null && break
  [ "$i" = 30 ] && { echo "ingress not responding"; exit 1; }
  sleep 2
done

echo
echo "Done. Try: curl -H 'Host: demo.local' http://localhost/"

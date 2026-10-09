#!/usr/bin/env bash
# One-command, idempotent setup: kind cluster -> ingress-nginx -> image -> Helm release.
# Safe to run repeatedly; every step either checks existing state or is declarative.
#
# Usage:
#   ./setup.sh          install or update everything
#   ./setup.sh delete   delete the kind cluster and the locally built images
set -euo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_REPO="demo-service"
INGRESS_NGINX_VERSION="controller-v1.15.1"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Delete ---------------------------------------------------------------------
# Everything (ingress-nginx, the release, the namespace) lives inside the kind
# cluster, so deleting the cluster removes it all. Also safe to run twice.
if [ "${1:-}" = "delete" ]; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "Deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    log "kind cluster '$CLUSTER_NAME' does not exist, nothing to delete"
  fi
  images="$(docker images -q "$IMAGE_REPO" | sort -u)"
  if [ -n "$images" ]; then
    log "Removing local '$IMAGE_REPO' images"
    # shellcheck disable=SC2086
    docker rmi -f $images >/dev/null
  fi
  log "Done."
  exit 0
elif [ -n "${1:-}" ]; then
  die "unknown argument '$1' (usage: ./setup.sh [delete])"
fi

# 0. Prerequisites -----------------------------------------------------------
for tool in docker kind kubectl helm curl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

# 1. kind cluster (create or reuse) -------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  log "Creating kind cluster '$CLUSTER_NAME'"
  # Map host ports 80/443 on this machine into the node. The ingress-nginx kind
  # manifest binds the controller to hostPort 80/443 on that node, so
  # http://localhost/ reaches ingress-nginx.
  kind create cluster --name "$CLUSTER_NAME" --wait 120s --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
fi
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

# 2. ingress-nginx -----------------------------------------------------------
log "Installing ingress-nginx ($INGRESS_NGINX_VERSION)"
kubectl apply -f "$INGRESS_NGINX_MANIFEST" >/dev/null
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

# 3. Build and load the image ----------------------------------------------------
# Tag = hash of the service sources: a code change gives a new tag (so the
# Deployment rolls), an unchanged tree gives the same tag (so re-runs are no-ops).
IMAGE_TAG="$(cd "$ROOT_DIR/service" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

log "Building $IMAGE"
docker build -t "$IMAGE" "$ROOT_DIR/service"

log "Loading $IMAGE into kind"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# 4. Helm release ------------------------------------------------------------
# The ingress-nginx admission webhook can briefly refuse connections right after
# the controller turns Ready, so retry the install a few times.
#
# Helm 4 uses server-side apply: if someone ran `kubectl patch` on the ConfigMap,
# the next upgrade fails with a field-manager conflict. The chart is the source
# of truth, so take those fields back. Helm 3 (client-side apply) has no such flag.
HELM_EXTRA_ARGS=()
if helm version --template '{{.Version}}' | grep -q '^v4'; then
  HELM_EXTRA_ARGS+=(--force-conflicts)
fi

log "Deploying Helm release '$RELEASE' to namespace '$NAMESPACE'"
for attempt in 1 2 3 4 5; do
  if helm upgrade --install "$RELEASE" "$ROOT_DIR/chart" \
      --namespace "$NAMESPACE" --create-namespace \
      ${HELM_EXTRA_ARGS[@]+"${HELM_EXTRA_ARGS[@]}"} \
      --set image.repository="$IMAGE_REPO" \
      --set image.tag="$IMAGE_TAG" \
      --wait --timeout 180s; then
    break
  fi
  [ "$attempt" -eq 5 ] && die "helm upgrade --install failed after $attempt attempts"
  echo "helm attempt $attempt failed, retrying in 10s..."
  sleep 10
done

# 5. Wait for the Ingress ---------------------------------------------------------
# `helm --wait` returns once the pods are Ready, but ingress-nginx picks up the new
# endpoints a few seconds later and answers 503 until then. Wait for a real 200.
log "Waiting for http://localhost/ (Host: demo.local) to return 200"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: demo.local' http://localhost/healthz || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || die "Ingress still returns HTTP $code after 60s"

log "Done. Verify with:"
cat <<EOF
  kubectl -n $NAMESPACE get pods,svc,ingress
  curl -H "Host: demo.local" http://localhost/
  curl -H "Host: demo.local" http://localhost/healthz
EOF

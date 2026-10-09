# Answers

## Q1 — Migrating ~40 Ingress objects from ingress-nginx to the Gateway API with no downtime

**Approach:** run both side by side, move traffic one host at a time, and keep
rollback one DNS change away. Never convert in place.

**Order**

1. **Inventory.** List all 40 Ingresses with their annotations, snippets, TLS
   secrets and the controller-wide nginx ConfigMap. Plain host/path rules
   convert mechanically; the annotations are where the risk is.
2. **Install a Gateway implementation next to ingress-nginx**, with its own
   load balancer IP. Nothing changes for users yet.
3. **Convert.** Use `ingress2gateway` as a first draft, then fix by hand. The
   new HTTPRoutes point at the same Services as the existing Ingresses.
4. **Test before touching DNS.** `curl --resolve host:443:<new-ip>` for every
   host; compare status codes, redirects and headers with the old path.
5. **Cut over in waves.** Lower DNS TTLs first, start with low-risk internal
   hosts, switch one host at a time (weighted DNS if available), watch error
   rate and latency, and leave the Ingress in place for rollback.
6. **Decommission** ingress-nginx only after its access logs show no traffic
   for a quiet period.

**What I expect to break**

- nginx-only annotations: regex `rewrite-target`, `configuration-snippet`,
  `auth-url`, rate limits, body-size and timeout defaults.
- TLS: cert-manager must issue for Gateways; cross-namespace secrets need a
  ReferenceGrant.
- Behaviour differences: path-matching rules, default timeouts, WebSocket and
  gRPC, sticky sessions, client-IP headers.
- Anything tied to the old IP or controller: firewall allow-lists,
  external-dns ownership, dashboards and alerts built on nginx metrics.

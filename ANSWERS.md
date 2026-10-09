# Answers

## Q1 — Moving ~40 Ingress objects from ingress-nginx to Gateway API with no downtime

**My approach:** run the old and the new side by side, move one host at a
time, and keep rollback as simple as one DNS change. I would not convert
anything in place.

**Order I would do it in**

1. **Make a list first.** All 40 Ingresses, with their annotations, snippets,
   TLS secrets and the nginx ConfigMap. Simple host/path rules are easy to
   convert. The annotations are the risky part.
2. **Install a Gateway controller next to ingress-nginx**, with its own load
   balancer IP. Users see no change yet.
3. **Convert.** Use `ingress2gateway` for a first draft and fix the rest by
   hand. The new HTTPRoutes point to the same Services as the old Ingresses.
4. **Test before DNS.** `curl --resolve host:443:<new-ip>` for every host,
   and compare status codes, redirects and headers with the old path.
5. **Switch in small groups.** Lower the DNS TTL first. Start with internal,
   low-risk hosts. Move one host at a time, watch errors and latency, and
   keep the old Ingress so I can switch back.
6. **Remove ingress-nginx last**, only when its access logs show no traffic
   for some days.

**What I expect to break**

- nginx-only annotations: regex `rewrite-target`, `configuration-snippet`,
  `auth-url`, rate limits, body size and timeout defaults.
- TLS: cert-manager has to issue for Gateways, and secrets in another
  namespace need a ReferenceGrant.
- Small behaviour differences: path matching, default timeouts, WebSocket
  and gRPC, sticky sessions, client IP headers.
- Things tied to the old IP or controller: firewall allow-lists,
  external-dns, and dashboards/alerts built on nginx metrics.

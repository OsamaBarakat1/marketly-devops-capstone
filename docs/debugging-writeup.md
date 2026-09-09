# One thing that broke: the catalog page 502'd, intermittently

Required by the submission checklist in
[`PROJECT_BRIEF.md`](./assignment/PROJECT_BRIEF.md) §7. Fixed in commit
`Re-resolve backend addresses in the frontend proxy`.

## The symptom

After rebuilding a single backend container during local Compose testing, the
storefront kept loading but the catalog page returned **502 Bad Gateway**.
Logging in still worked. Placing an order still worked. Only `/api/products`
failed — and only sometimes, which is what made it look like a flake rather
than a bug.

Restarting the frontend container fixed it every time. That detail turned out
to be the whole answer, but at first it read as evidence *against* a frontend
problem: the frontend had not changed, so why would restarting it help?

## What made it confusing

Three things pointed in the wrong direction.

First, the failing component was healthy. `docker compose ps` showed
catalog-service up, and `curl http://localhost:5002/health` from the host
returned `{"status": "ok"}`. The service being proxied *to* was fine.

Second, the error moved. Rebuild a different service and a different API path
would start failing instead. That looked like a load or timing problem, not a
configuration one.

Third, and most misleading: the proxy was not returning "connection refused".
It was reaching *something*. A 502 with an immediate response means a TCP
connection was established and the answer was not valid HTTP for that route —
not that nothing was listening.

## Finding it

The step that turned it around was comparing what Nginx thought the upstream
was against what Docker had actually assigned:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' marketly-catalog-service-1
# 172.22.0.7

docker exec marketly-frontend-1 cat /proc/net/tcp   # translated: still dialling 172.22.0.4
```

`172.22.0.4` was the address catalog-service had held *before* the rebuild.
Worse, Docker had since handed that freed address to **auth-service**. So the
proxy was opening a healthy TCP connection to a real, running service — just
the wrong one. auth-service does not serve `/api/products` on 5002, so it
answered in a way Nginx surfaced as a 502.

That explains all three confusing signals at once: the target service was
genuinely healthy, the symptom followed whichever container was rebuilt last,
and the connection succeeded because something really was listening.

## The cause

Nginx resolves a hostname written literally into `proxy_pass` **once**, when
the configuration loads, and then caches that address for the life of the
worker process. Container addresses are not stable — recreating a backend
gives it a new one — so the proxy kept dialling an address that had moved.

This is easy to miss because it is invisible until something restarts. A
stack brought up once and left alone never shows it.

## The fix

Name a resolver and route each upstream through a variable, which forces
Nginx to look the name up per request and honour a TTL
([`frontend/nginx.conf.template`](../frontend/nginx.conf.template)):

```nginx
resolver ${DNS_RESOLVER} valid=10s ipv6=off;

location /api/products {
    set $catalog_upstream "http://${CATALOG_SERVICE_HOST}:${CATALOG_SERVICE_PORT}";
    proxy_pass $catalog_upstream$request_uri;
}
```

`$request_uri` is appended explicitly because `proxy_pass` with a variable
does not inherit the request URI the way a literal one does. Leaving it off
swaps the 502 for a 404, which is an even more confusing symptom.

## Verifying it

The bug only appears when an address changes, so the test has to change one.
catalog-service was moved from `172.22.0.4` to `172.22.0.7` **with Nginx left
running**. The proxy recovered on its own within the 10-second TTL, where
before it would have served 502 until restarted.

## What it changed about the rest of the project

The same failure exists in Kubernetes, and the same reasoning shaped two
decisions there.

Pods get new IPs constantly, far more often than containers do locally. In
the cluster the `/api/*` paths never reach the frontend pod at all — the
Traefik Ingress routes them straight to the backend Services, and Traefik
watches the Kubernetes API for Endpoint changes rather than caching a
resolved address. The Nginx proxy paths survive in the image only so the same
build works under `docker compose`.

More generally, it is the reason
[`k8s/configmap.yaml`](../k8s/configmap.yaml) points orders-service at
`http://catalog-service:5002` — a Service DNS name whose ClusterIP is stable
for the life of the Service — rather than at anything resolved once and held.
The lesson was not "add a resolver". It was that in a containerised system,
any address cached at startup is a bug waiting for the next restart.

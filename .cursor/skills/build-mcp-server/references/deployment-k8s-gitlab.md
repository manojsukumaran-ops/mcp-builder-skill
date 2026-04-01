# Docker & Kubernetes Deployment with GitLab CI/CD

Production deployment guide for enterprise MCP servers. Template files live in
`assets/` — read them directly and adapt `{service}` and `{namespace}` to match
the user's answers from Phase 1.

---

## Asset Files

| File | Purpose |
|------|---------|
| `assets/Dockerfile` | Multi-stage build: builder installs deps, runtime is non-root |
| `assets/.dockerignore` | Excludes `.env`, tests, k8s/, secrets from image |
| `assets/docker-compose.yml` | Local dev with hot-reload and `DISABLE_AUTH=true` |
| `assets/.gitlab-ci.yml` | CI pipeline: test → build → deploy-staging → deploy-production |
| `assets/k8s/configmap.yaml` | Non-secret env vars (safe to commit) |
| `assets/k8s/deployment.yaml` | Deployment with security context; `IMAGE_PLACEHOLDER` is replaced by CI |
| `assets/k8s/service.yaml` | ClusterIP: port 80 → container 8000 |
| `assets/k8s/hpa.yaml` | HPA scaling on CPU (70%) and memory (80%) |
| `assets/k8s/ingress.yaml` | Optional — for external cluster access |

Read each asset file before generating it for the user's project. Apply these
substitutions throughout:

| Placeholder | Replace with |
|-------------|-------------|
| `{service}` | User's service name from Phase 1 (snake_case, e.g. `payments`) |
| `{namespace}` | Target k8s namespace (ask if not provided; default: `default`) |
| `IMAGE_PLACEHOLDER` | Leave as-is in the committed manifest — CI replaces it via `sed` |

---

## Project Layout Addition

```
{service}_mcp/
├── Dockerfile
├── .dockerignore
├── docker-compose.yml
├── .gitlab-ci.yml
└── k8s/
    ├── configmap.yaml
    ├── deployment.yaml     ← IMAGE_PLACEHOLDER stamped by .gitlab-ci.yml
    ├── service.yaml
    ├── hpa.yaml
    └── ingress.yaml        ← optional
```

Add these patterns to `.gitignore` (already included in scaffold-fastmcp.md):
```
k8s/*-secret.yaml
k8s/secret.yaml
.env.secrets
```

---

## Secrets Management

**Never commit a `k8s/secret.yaml` with real values.**

### Option 1 — Manual `kubectl` (simplest)

```bash
kubectl create secret generic {service}-mcp-secrets \
  --namespace={namespace} \
  --from-literal=OAUTH_CLIENT_ID=your-client-id \
  --from-literal=OAUTH_CLIENT_SECRET=your-client-secret
```

### Option 2 — GitLab CI injects secrets at deploy time (recommended)

Store as masked GitLab CI/CD variables (`K8S_MCP_CLIENT_ID`, `K8S_MCP_CLIENT_SECRET`).
The `.gitlab-ci.yml` already includes the idempotent `kubectl create secret --dry-run | apply` pattern.

### Option 3 — External Secrets Operator

For teams using Vault, AWS Secrets Manager, or GCP Secret Manager:

```yaml
# k8s/external-secret.yaml (safe to commit — no real values)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {service}-mcp-secrets
  namespace: {namespace}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend     # or aws-secrets-manager, gcp-sm, azure-kv
    kind: ClusterSecretStore
  target:
    name: {service}-mcp-secrets
  data:
    - secretKey: OAUTH_CLIENT_ID
      remoteRef:
        key: mcp/{service}
        property: client_id
    - secretKey: OAUTH_CLIENT_SECRET
      remoteRef:
        key: mcp/{service}
        property: client_secret
```

---

## Adding a `/health` Endpoint

The k8s manifests use TCP socket probes by default (safe with any FastMCP version).
To upgrade to HTTP probes, add a `/health` route alongside the FastMCP ASGI app:

```python
# src/server.py additions
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})

health_app = Starlette(routes=[Route("/health", health)])
# Compose with FastMCP ASGI app per FastMCP docs for your version.
```

Then update `k8s/deployment.yaml` probes from `tcpSocket` to:
```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8000
```

---

## `readOnlyRootFilesystem` Note

`assets/k8s/deployment.yaml` sets `readOnlyRootFilesystem: true` with `emptyDir`
mounts for `/tmp` and `/app/__pycache__`. Test first with:

```bash
docker run --read-only --tmpfs /tmp --env-file .env {service}-mcp:local
```

If the container crashes, identify the write path from the error and add an
`emptyDir` volumeMount for it. Remove the flag only as a last resort.

---

## Quick Reference Commands

```bash
# Local
docker compose up --build
docker run --env-file .env -p 8000:8000 {service}-mcp:local

# Manual k8s deploy (without CI)
export IMAGE_TAG=local
sed -i "s|IMAGE_PLACEHOLDER|registry/{service}-mcp:$IMAGE_TAG|g" k8s/deployment.yaml
kubectl apply -f k8s/
kubectl rollout status deployment/{service}-mcp -n {namespace}

# Observe
kubectl get pods -n {namespace} -l app={service}-mcp
kubectl logs -n {namespace} -l app={service}-mcp --tail=50 -f

# Rollback
kubectl rollout undo deployment/{service}-mcp -n {namespace}
```

# FastMCP Scaffold

Complete project scaffold for an enterprise FastMCP Python server. Every
pattern here integrates with `auth-patterns.md`, `oauth-middleware.md`, and
`tool-logging.md`.

---

## Project Layout

```
{service}_mcp/
├── pyproject.toml
├── .env.example
├── .gitignore
├── Dockerfile              ← multi-stage build (see deployment-k8s-gitlab.md)
├── docker-compose.yml      ← local dev
├── .dockerignore
├── .gitlab-ci.yml          ← test → build → deploy-staging → deploy-production
├── README.md
├── src/
│   ├── __init__.py
│   ├── server.py           ← FastMCP init, lifespan, middleware wiring
│   ├── config.py           ← pydantic-settings Settings class
│   ├── auth.py             ← TokenManager (outbound OAuth)
│   ├── middleware.py       ← OAuthMiddleware + NoOpMiddleware (inbound)
│   ├── logging_utils.py    ← log_tool_call decorator + setup_logging()
│   ├── http_client.py      ← shared httpx.AsyncClient factory with retry
│   └── tools/
│       ├── __init__.py     ← empty, required for package import
│       └── {resource}.py   ← one file per resource group
├── k8s/
│   ├── configmap.yaml      ← non-secret env vars
│   ├── deployment.yaml     ← Deployment + security context (IMAGE_PLACEHOLDER)
│   ├── service.yaml        ← ClusterIP
│   ├── hpa.yaml            ← HorizontalPodAutoscaler
│   └── ingress.yaml        ← optional, for external access
└── tests/
    ├── conftest.py
    └── test_{resource}.py
```

---

## `pyproject.toml`

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "{service}-mcp"
version = "0.1.0"
description = "MCP server for {Service}"
requires-python = ">=3.11"
dependencies = [
    "fastmcp>=2.3.0",
    "httpx>=0.27.0",
    "pydantic>=2.7.0",
    "pydantic-settings>=2.3.0",
    "PyJWT[crypto]>=2.8.0",   # only if using inbound OAuth validation
    "tenacity>=8.3.0",        # retry/backoff for transient upstream errors
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "pytest-httpx>=0.30.0",
    "pytest-cov>=5.0.0",
]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
addopts = "--tb=short"

[tool.hatch.build.targets.wheel]
packages = ["src"]
```

---

## `.env.example`

```bash
# ── Upstream API ──────────────────────────────────────────────────────────
UPSTREAM_API_BASE_URL=https://api.example.com

# ── Outbound auth (pick one method, remove the others) ────────────────────

# Method: OAuth 2.0 client credentials (recommended for M2M)
TOKEN_ENDPOINT=https://auth.example.com/oauth/token
OAUTH_CLIENT_ID=
OAUTH_CLIENT_SECRET=
OAUTH_SCOPES=read:data write:data

# Method: API key
# API_KEY=

# Method: Static Bearer token
# BEARER_TOKEN=

# ── Inbound OAuth validation (uncomment if MCP clients must present a token)
# DISABLE_AUTH=false
# OAUTH_VALIDATION_MODE=jwks
# JWKS_URI=https://your-tenant.auth0.com/.well-known/jwks.json
# OAUTH_AUDIENCE=https://api.your-service.com
# OAUTH_ISSUER=https://your-tenant.auth0.com/
# REQUIRED_SCOPE=mcp:read

# ── Observability ──────────────────────────────────────────────────────────
LOG_LEVEL=INFO
```

---

## `.gitignore`

```gitignore
# Environment — never commit secrets
.env
.env.local
.env.*.local
.env.secrets

# Kubernetes secrets — never commit real values
k8s/*-secret.yaml
k8s/secret.yaml
k8s/secrets.yaml

# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/
dist/
build/

# Test / coverage artifacts
.pytest_cache/
.coverage
htmlcov/
coverage.xml

# IDE
.vscode/
.idea/
```

---

## `src/tools/__init__.py`

```python
# src/tools/__init__.py
# Empty — required for Python to treat tools/ as a package.
# Tool modules are imported explicitly in server.py to trigger @mcp.tool registration.
```

---

## `src/config.py`

```python
# src/config.py
from typing import Literal
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Upstream API
    upstream_api_base_url: str

    # Outbound auth — OAuth 2.0 client credentials
    token_endpoint: str = ""
    oauth_client_id: str = ""
    oauth_client_secret: str = ""
    oauth_scopes: str = ""

    # Outbound auth — alternatives (comment out unused)
    # api_key: str = ""
    # bearer_token: str = ""

    # Inbound OAuth validation
    disable_auth: bool = False
    oauth_validation_mode: Literal["jwks", "introspect"] = "jwks"
    jwks_uri: str = ""
    oauth_audience: str = ""
    oauth_issuer: str = ""
    introspection_endpoint: str = ""
    required_scope: str = ""

    # Observability
    log_level: str = "INFO"


# Module-level singleton — imported by all other modules
settings = Settings()
```

---

## `src/server.py`

```python
# src/server.py
"""
{Service} MCP Server

Exposes {Service} operations as MCP tools with:
- OAuth middleware for inbound token validation
- TokenManager for outbound API authentication
- Structured JSON logging on every tool call
"""
from contextlib import asynccontextmanager
from fastmcp import FastMCP

from src.config import settings
from src.auth import TokenManager
from src.logging_utils import setup_logging

# Configure logging before anything else
setup_logging()

import logging
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(server: FastMCP):
    """
    Server lifecycle: initialize shared resources, yield them to tools,
    then clean up on shutdown.
    """
    logger.info("server_starting", extra={"service": "{service}_mcp"})

    token_manager = TokenManager(settings)
    await token_manager.initialize()

    yield {"token_manager": token_manager}

    await token_manager.close()
    logger.info("server_stopped")


mcp = FastMCP("{service}_mcp", lifespan=lifespan)

# Register middleware
from src.middleware import OAuthMiddleware, NoOpMiddleware  # noqa: E402

if settings.disable_auth:
    mcp.add_middleware(NoOpMiddleware())
else:
    mcp.add_middleware(OAuthMiddleware(settings))

# Import tool modules to trigger @mcp.tool registration
# Add one import per resource file in src/tools/
from src.tools import {resource}  # noqa: E402, F401
```

---

## `src/http_client.py`

```python
# src/http_client.py
import logging
import httpx
from tenacity import (
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)

logger = logging.getLogger(__name__)

# Retry on transient server errors and rate limits (not on 4xx client errors)
_RETRYABLE_STATUSES = {429, 502, 503, 504}


def _is_retryable(exc: BaseException) -> bool:
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in _RETRYABLE_STATUSES
    if isinstance(exc, (httpx.TimeoutException, httpx.ConnectError)):
        return True
    return False


def _log_request(request: httpx.Request) -> None:
    logger.debug(
        "upstream_request",
        extra={"method": request.method, "url": str(request.url)},
    )


def _log_response(response: httpx.Response) -> None:
    logger.info(
        "upstream_response",
        extra={"status": response.status_code, "url": str(response.url)},
    )


def get_client(token: str) -> httpx.AsyncClient:
    """
    Return an authenticated async HTTP client for the upstream API.

    Retry policy: up to 3 attempts with exponential backoff (1s → 2s → 4s)
    on 429, 502, 503, 504, and network-level errors.

    Usage (always use as async context manager):
        async with get_client(token) as client:
            resp = await client.get("/resource")
            resp.raise_for_status()   # trigger retry on 5xx
    """
    from src.config import settings  # avoid circular import at module level

    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30.0,
        event_hooks={
            "request": [_log_request],
            "response": [_log_response],
        },
    )


@retry(
    retry=retry_if_exception(_is_retryable),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=8),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
async def get_with_retry(client: httpx.AsyncClient, path: str, **kwargs) -> httpx.Response:
    """
    GET with automatic retry on transient errors.
    Use instead of `client.get()` for read operations where retrying is safe.

    Example:
        async with get_client(token) as client:
            resp = await get_with_retry(client, "/users", params=query)
    """
    resp = await client.get(path, **kwargs)
    resp.raise_for_status()
    return resp


@retry(
    retry=retry_if_exception(_is_retryable),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=8),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
async def post_with_retry(client: httpx.AsyncClient, path: str, **kwargs) -> httpx.Response:
    """
    POST with retry — only use for idempotent operations (e.g., upserts).
    Do NOT use for non-idempotent creates where a duplicate would be harmful.
    """
    resp = await client.post(path, **kwargs)
    resp.raise_for_status()
    return resp
```

**When to use retry helpers vs. plain `client.get()`:**

| Operation | Use retry? | Reason |
|---|---|---|
| `list_*`, `get_*` | Yes — `get_with_retry` | Safe to retry reads |
| `create_*` | No — plain `client.post()` | Duplicate creates on retry |
| `update_*` (PATCH, idempotent) | Yes — `post_with_retry` | Same result on retry |
| `delete_*` | Yes (usually) | Idempotent if 404 is handled |

---

## Response Shaping for LLM Consumption

Raw upstream JSON is often deeply nested or contains hundreds of fields the LLM
doesn't need. This degrades tool selection and increases token cost.

**Rules for tool return values:**
1. Return only the fields Claude needs to answer the user's request
2. Flatten nested objects one level (avoid `user.profile.contact.email`)
3. Truncate large arrays — return at most 20-50 items with `has_more`
4. Add a human-readable `summary` key alongside raw data when helpful
5. Never return binary data, base64 blobs, or full HTML in tool responses

```python
# Instead of returning raw upstream JSON:
return json.dumps(resp.json())  # may be 200 fields deep

# Shape the response:
raw = resp.json()
return json.dumps({
    "id": raw["id"],
    "name": raw["displayName"],
    "email": raw["contactInfo"]["primaryEmail"],  # flatten one level
    "active": raw["status"] == "ACTIVE",
    "role": raw["permissions"]["primaryRole"],
    "created_at": raw["auditInfo"]["createdAt"],
    # Omit: raw audit log, internal IDs, feature flags, etc.
})
```

---

## `src/tools/{resource}.py` — Complete Example

This example uses a "users" resource. Replace `user`/`users`/`User` throughout.

```python
# src/tools/users.py
"""
User management MCP tools.

Tools:
  list_users   — List users with optional filters and pagination
  get_user     — Fetch a single user by ID
  create_user  — Create a new user
  update_user  — Update user fields
  deactivate_user — Deactivate (soft-delete) a user
"""
import json
import logging
from typing import Annotated, Optional

import httpx
from fastmcp import Context
from pydantic import BaseModel, ConfigDict, Field

from src.server import mcp
from src.auth import TokenManager
from src.http_client import get_client
from src.logging_utils import log_tool_call

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Input models — ConfigDict(extra='forbid') rejects unknown fields
# ---------------------------------------------------------------------------

class ListUsersInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    limit: Annotated[int, Field(ge=1, le=100, description="Max results")] = 20
    offset: Annotated[int, Field(ge=0, description="Pagination offset")] = 0
    active_only: bool = True
    search: Optional[str] = Field(
        None, description="Filter by name or email substring"
    )


class GetUserInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: Annotated[str, Field(min_length=1, description="User ID")]


class CreateUserInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Annotated[str, Field(min_length=1, max_length=100)]
    email: Annotated[str, Field(pattern=r"^[^@]+@[^@]+\.[^@]+$")]
    role: Annotated[str, Field(description="e.g., 'viewer', 'editor', 'admin'")] = "viewer"


class UpdateUserInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: Annotated[str, Field(min_length=1)]
    name: Optional[str] = None
    role: Optional[str] = None


class DeactivateUserInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: Annotated[str, Field(min_length=1)]
    reason: Optional[str] = Field(None, max_length=500)


# ---------------------------------------------------------------------------
# Error helper — consistent error strings for all HTTP errors
# ---------------------------------------------------------------------------

def _handle_api_error(response: httpx.Response) -> str:
    status = response.status_code
    if status == 401:
        return "Error: Authentication failed. Check your API credentials."
    if status == 403:
        return "Error: Forbidden. Your credentials lack the required permissions."
    if status == 404:
        return "Error: User not found."
    if status == 409:
        return "Error: Conflict — a user with this email already exists."
    if status == 422:
        try:
            detail = response.json().get("error", response.text[:200])
        except Exception:
            detail = response.text[:200]
        return f"Error: Validation error from API — {detail}"
    if status == 429:
        return "Error: Rate limit exceeded. Please retry after a short delay."
    if status >= 500:
        return f"Error: Upstream service error ({status}). Try again later."
    return f"Error: Unexpected response ({status}): {response.text[:200]}"


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool(
    name="list_users",
    description=(
        "List users with optional filters. Returns a paginated JSON response "
        "with 'users', 'total', 'has_more', and 'next_offset' fields."
    ),
    annotations={"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True},
)
@log_tool_call
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    query: dict = {
        "limit": params.limit,
        "offset": params.offset,
        "active": params.active_only,
    }
    if params.search:
        query["search"] = params.search

    try:
        async with get_client(token) as client:
            resp = await client.get("/users", params=query)
    except httpx.TimeoutException:
        return "Error: Request timed out. The upstream API did not respond in time."

    if not resp.is_success:
        return _handle_api_error(resp)

    data = resp.json()
    users = data.get("users", [])

    if not users:
        return "No users found matching your criteria."

    total = data.get("total", len(users))
    has_more = (params.offset + len(users)) < total
    next_offset = params.offset + len(users) if has_more else None

    return json.dumps({
        "users": users,
        "total": total,
        "returned": len(users),
        "has_more": has_more,
        "next_offset": next_offset,
    })


@mcp.tool(
    name="get_user",
    description="Fetch a single user by their ID.",
    annotations={"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True},
)
@log_tool_call
async def get_user(params: GetUserInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    try:
        async with get_client(token) as client:
            resp = await client.get(f"/users/{params.id}")
    except httpx.TimeoutException:
        return "Error: Request timed out."

    if not resp.is_success:
        return _handle_api_error(resp)

    return json.dumps(resp.json())


@mcp.tool(
    name="create_user",
    description=(
        "Create a new user account. Returns the created user object including "
        "the assigned ID."
    ),
    annotations={"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False},
)
@log_tool_call
async def create_user(params: CreateUserInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    try:
        async with get_client(token) as client:
            resp = await client.post(
                "/users",
                json=params.model_dump(),
            )
    except httpx.TimeoutException:
        return "Error: Request timed out."

    if not resp.is_success:
        return _handle_api_error(resp)

    created = resp.json()
    return json.dumps({
        "success": True,
        "user": created,
        "message": f"User '{params.name}' created with ID {created.get('id')}.",
    })


@mcp.tool(
    name="update_user",
    description="Update one or more fields of an existing user.",
    annotations={"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True},
)
@log_tool_call
async def update_user(params: UpdateUserInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    body = params.model_dump(exclude={"id"}, exclude_none=True)
    if not body:
        return "Error: No fields to update were provided."

    try:
        async with get_client(token) as client:
            resp = await client.patch(f"/users/{params.id}", json=body)
    except httpx.TimeoutException:
        return "Error: Request timed out."

    if not resp.is_success:
        return _handle_api_error(resp)

    return json.dumps({"success": True, "user": resp.json()})


@mcp.tool(
    name="deactivate_user",
    description=(
        "Deactivate a user account. The user will no longer be able to log in "
        "but their data is preserved. This action can be reversed by an admin."
    ),
    annotations={"readOnlyHint": False, "destructiveHint": True, "idempotentHint": True},
)
@log_tool_call
async def deactivate_user(params: DeactivateUserInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    body: dict = {"active": False}
    if params.reason:
        body["deactivation_reason"] = params.reason

    try:
        async with get_client(token) as client:
            resp = await client.patch(f"/users/{params.id}", json=body)
    except httpx.TimeoutException:
        return "Error: Request timed out."

    if not resp.is_success:
        return _handle_api_error(resp)

    return json.dumps({
        "success": True,
        "message": f"User {params.id} has been deactivated.",
    })
```

---

## Running the Server

```bash
# Install dependencies
pip install -e ".[dev]"
# or with uv:
uv pip install -e ".[dev]"

# Copy and fill environment variables
cp .env.example .env
# Edit .env with real credentials

# Run tests first
pytest tests/ -v --cov=src --cov-report=term-missing

# Run as stdio server (Claude Code, local)
fastmcp run src/server.py

# Run as HTTP server (remote, any MCP client)
fastmcp run src/server.py --transport streamable-http --port 8000
```

---

## Docker

For the full multi-stage `Dockerfile`, `docker-compose.yml`, `.dockerignore`,
Kubernetes manifests (`k8s/`), and GitLab CI/CD pipeline (`.gitlab-ci.yml`),
load `references/deployment-k8s-gitlab.md`.

Quick start:

```bash
# Build and run locally
docker build -t {service}-mcp:local .
docker run --env-file .env -p 8000:8000 {service}-mcp:local

# Or with docker compose (hot-reload + DISABLE_AUTH=true)
docker compose up --build
```

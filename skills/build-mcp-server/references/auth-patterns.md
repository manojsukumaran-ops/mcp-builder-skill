# Auth Patterns

Reference for authentication in MCP servers — both directions:

- **Methods 1–7:** Outbound auth — credentials your MCP server uses when
  calling an upstream REST API.
- **Method 8:** Inbound auth — validating Bearer tokens presented by MCP
  clients (Claude, agents) before any tool executes. Full implementation in
  `references/oauth-middleware.md`.

---

## Env Var Naming Conventions

Use these standard names in `.env.example` and `config.py` for consistency:

```
# Upstream API
UPSTREAM_API_BASE_URL=https://api.example.com

# Auth — choose one section based on method

# --- API Key ---
API_KEY=

# --- OAuth 2.0 Client Credentials ---
TOKEN_ENDPOINT=https://auth.example.com/oauth/token
OAUTH_CLIENT_ID=
OAUTH_CLIENT_SECRET=
OAUTH_SCOPES=read:data write:data

# --- Static Bearer Token ---
BEARER_TOKEN=

# --- Basic Auth ---
BASIC_AUTH_USERNAME=
BASIC_AUTH_PASSWORD=

# --- mTLS ---
MTLS_CERT_PATH=/etc/certs/client.crt
MTLS_KEY_PATH=/etc/certs/client.key
MTLS_CA_PATH=/etc/certs/ca.crt

# --- Custom Header ---
CUSTOM_HEADER_NAME=X-Api-Token
CUSTOM_HEADER_VALUE=
```

---

## Method 1: API Key

**When to use:** Service uses a static key in a header or query param.

```python
# src/config.py addition
class Settings(BaseSettings):
    upstream_api_base_url: str
    api_key: str

# src/http_client.py
def get_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        headers={"Authorization": f"Bearer {settings.api_key}"},
        # or: headers={"X-API-Key": settings.api_key}
        timeout=30.0,
        event_hooks={
            "request": [_log_request],
            "response": [_log_response],
        },
    )
```

No `TokenManager` needed. Inject directly from settings.

**Test pattern:**
```python
async def test_api_key_injected(httpx_mock: HTTPXMock, mock_context):
    httpx_mock.add_response(json={"data": []})
    await list_items(ListItemsInput(), mock_context)
    request = httpx_mock.get_requests()[0]
    assert request.headers["Authorization"] == "Bearer test-api-key"
```

---

## Method 2: OAuth 2.0 Client Credentials (Recommended for M2M)

**When to use:** Server-to-server (machine-to-machine) integration. Most common
enterprise pattern. Your server obtains a short-lived access token using
`client_id` + `client_secret`, caches it, and refreshes before expiry.

### Full TokenManager Implementation

```python
# src/auth.py
import asyncio
import time
import logging
import httpx
from src.config import Settings

logger = logging.getLogger(__name__)


class TokenManager:
    """
    Manages OAuth 2.0 client credentials tokens for outbound API calls.

    - Thread-safe: asyncio.Lock prevents concurrent refresh storms.
    - Proactive refresh: refreshes 30 seconds before actual expiry.
    - initialize() is called in FastMCP lifespan so the first tool call
      never blocks on token acquisition.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._token: str | None = None
        self._expires_at: float = 0.0
        self._lock = asyncio.Lock()
        self._client: httpx.AsyncClient | None = None

    async def initialize(self) -> None:
        """Call during server lifespan startup. Fails fast if creds are wrong."""
        self._client = httpx.AsyncClient(timeout=30.0)
        await self._refresh()
        logger.info("token_manager_initialized")

    async def close(self) -> None:
        """Call during server lifespan shutdown."""
        self._token = None
        if self._client:
            await self._client.aclose()
        logger.info("token_manager_closed")

    async def get_token(self) -> str:
        """Return a valid access token, refreshing if needed."""
        async with self._lock:
            if self._token and time.monotonic() < self._expires_at:
                return self._token
            await self._refresh()
            return self._token  # type: ignore[return-value]

    async def _refresh(self) -> None:
        assert self._client is not None, "TokenManager not initialized"
        logger.info("token_refresh_start")
        try:
            resp = await self._client.post(
                self._settings.token_endpoint,
                data={
                    "grant_type": "client_credentials",
                    "client_id": self._settings.oauth_client_id,
                    "client_secret": self._settings.oauth_client_secret,
                    "scope": self._settings.oauth_scopes,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            self._token = data["access_token"]
            expires_in = data.get("expires_in", 3600)
            # Refresh 30 seconds before actual expiry
            self._expires_at = time.monotonic() + expires_in - 30
            logger.info(
                "token_refresh_success",
                extra={"expires_in": expires_in},
            )
        except httpx.HTTPStatusError as exc:
            logger.error(
                "token_refresh_failed",
                extra={"status": exc.response.status_code},
            )
            raise
        except Exception:
            logger.error("token_refresh_failed", exc_info=True)
            raise
```

### Wiring TokenManager into FastMCP Lifespan

```python
# src/server.py
from contextlib import asynccontextmanager
from fastmcp import FastMCP
from src.auth import TokenManager
from src.config import settings

@asynccontextmanager
async def lifespan(server: FastMCP):
    token_manager = TokenManager(settings)
    await token_manager.initialize()
    yield {"token_manager": token_manager}
    await token_manager.close()

mcp = FastMCP("{service}_mcp", lifespan=lifespan)
```

### Using the Token in a Tool

```python
# src/tools/users.py
from fastmcp import Context
from src.auth import TokenManager
from src.http_client import get_client

@mcp.tool(name="list_users", ...)
@log_tool_call
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()
    async with get_client(token) as client:
        resp = await client.get("/users", params=params.model_dump(exclude_none=True))
    return _handle_response(resp)
```

Never store the token in a global or module-level variable. Always fetch via
`ctx.request_context.lifespan_state["token_manager"]`.

### Config Fields Required

```python
# src/config.py
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    upstream_api_base_url: str
    token_endpoint: str
    oauth_client_id: str
    oauth_client_secret: str
    oauth_scopes: str = ""
```

---

## Method 3: OAuth 2.0 Authorization Code Flow

**When to use:** User-delegated access (the MCP server acts on behalf of a
specific user, not the server itself).

This pattern is less common for MCP server-to-server use. It requires:
- A frontend callback URL to receive the authorization code
- Per-user token storage (not a shared `TokenManager`)
- A session/user identifier passed through the MCP context

**Recommendation:** If you need this pattern, design the OAuth callback as a
separate web endpoint outside the MCP server. Store tokens in a database keyed
by user ID, and look up the token per tool call. Do not use the shared
`TokenManager` from Method 2.

---

## Method 4: Static Bearer Token

**When to use:** Token does not expire, provided by the API vendor directly.

```python
# src/config.py
class Settings(BaseSettings):
    upstream_api_base_url: str
    bearer_token: str

# src/http_client.py
def get_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        headers={"Authorization": f"Bearer {settings.bearer_token}"},
        timeout=30.0,
    )
```

No `TokenManager` needed. Inject directly from settings. Note in README that
the token must be rotated manually when it expires or is revoked.

---

## Method 5: Basic Auth

**When to use:** Legacy APIs or internal services.

```python
# src/http_client.py
def get_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        auth=httpx.BasicAuth(
            username=settings.basic_auth_username,
            password=settings.basic_auth_password,
        ),
        timeout=30.0,
    )
```

**Security note:** Only use Basic Auth over HTTPS. Add this warning to the
generated README.

---

## Method 6: mTLS (Mutual TLS)

**When to use:** High-security internal APIs, financial services, healthcare.

```python
# src/config.py
class Settings(BaseSettings):
    upstream_api_base_url: str
    mtls_cert_path: str
    mtls_key_path: str
    mtls_ca_path: str

# src/http_client.py
def get_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        cert=(settings.mtls_cert_path, settings.mtls_key_path),
        verify=settings.mtls_ca_path,
        timeout=30.0,
    )
```

Cert paths must be env-var configurable. Never hardcode paths. In Docker/k8s,
mount certs as secrets volumes and point env vars at the mount path.

---

## Method 7: Custom Header

**When to use:** Proprietary APIs with non-standard auth schemes.

```python
# src/config.py
class Settings(BaseSettings):
    upstream_api_base_url: str
    custom_header_name: str   # e.g., "X-Service-Token"
    custom_header_value: str

# src/http_client.py
def get_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        headers={settings.custom_header_name: settings.custom_header_value},
        timeout=30.0,
    )
```

---

## Method 8: Inbound Token Validation (FastMCP Middleware)

**When to use:** Your MCP server is deployed with **streamable-HTTP transport**
and must verify that the caller (Claude, an agent, or any MCP client) presents
a valid Bearer token before any tool executes.

**stdio transport:** Skip this entirely. stdio is a local process — the caller
is the authenticated local user running Claude Code.

**Why middleware and not tool-level checks:**
- Single enforcement point — new tools are protected automatically
- Returns 401/403 before tool deserialization — no wasted compute
- Keeps auth logic out of business logic

```
MCP Client (Claude / agent)
    │  Authorization: Bearer <client_token>
    ▼
[OAuthMiddleware]   ← validates WHO IS CALLING your MCP server  (inbound)
    ▼
[Tool Handler]
    │
    ▼
[TokenManager]      ← generates tokens for calling the UPSTREAM API  (outbound)
    │  Authorization: Bearer <server_token>
    ▼
Upstream REST API
```

**Two validation modes** (choose one, configure via `OAUTH_VALIDATION_MODE`):

| Mode | Token type | Network cost | When to use |
|------|-----------|-------------|-------------|
| `jwks` | JWT (signed) | Zero after first call (keys cached 1 h) | Auth0, Okta, Azure AD, Keycloak, Google |
| `introspect` | Opaque or JWT | One round-trip per call | Tokens that are not JWTs, or when local validation is not possible |

**Required env vars:**

```bash
DISABLE_AUTH=false                  # true only for local dev without an IdP
OAUTH_VALIDATION_MODE=jwks          # or: introspect

# JWKS mode
JWKS_URI=https://your-idp/.well-known/jwks.json
OAUTH_AUDIENCE=https://api.your-service.com
OAUTH_ISSUER=https://your-idp/

# Introspect mode (instead of JWKS vars above)
INTROSPECTION_ENDPOINT=https://your-idp/oauth/introspect

# Shared — leave empty to skip global scope check
# Use @require_scope on individual tools for per-tool scope enforcement
REQUIRED_SCOPE=
```

**Per-tool scope enforcement** (when different tools need different scopes):

```python
from src.middleware import require_scope

@mcp.tool(name="list_users", annotations={"readOnlyHint": True})
@log_tool_call
@require_scope("read:users")          # ← enforces scope before tool runs
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    ...

@mcp.tool(name="delete_user", annotations={"destructiveHint": True})
@log_tool_call
@require_scope("admin:users")         # ← stricter scope for destructive tools
async def delete_user(params: DeleteUserInput, ctx: Context) -> str:
    ...
```

See `references/oauth-middleware.md` for the full `OAuthMiddleware`,
`NoOpMiddleware`, and `require_scope` implementations.

---

## Shared HTTP Client Pattern (apply to all methods)

Every method should use event hooks for upstream call logging:

```python
# src/http_client.py
import logging
import httpx

logger = logging.getLogger(__name__)


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
    Factory for an authenticated httpx client.
    Use as an async context manager in tool handlers.
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
```

## Error Response Helper

Include this in every tool file for consistent error messages:

```python
def _handle_api_error(response: httpx.Response) -> str:
    status = response.status_code
    if status == 401:
        return "Error: Authentication failed. Check your API credentials."
    if status == 403:
        return "Error: Forbidden. Your credentials lack the required permissions."
    if status == 404:
        return "Error: Resource not found."
    if status == 429:
        return "Error: Rate limit exceeded. Please retry after a short delay."
    if status >= 500:
        return f"Error: Upstream service error ({status}). Try again later."
    return f"Error: Unexpected response ({status}): {response.text[:200]}"
```

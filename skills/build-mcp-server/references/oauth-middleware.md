# OAuth Middleware (Inbound Auth)

This middleware validates OAuth Bearer tokens presented by **MCP clients
(Claude, agents) when calling your MCP server**. This is the inbound side.

Do not confuse with `auth.py` (`TokenManager`), which handles outbound tokens
your server uses to call an upstream REST API.

---

## Architecture

```
MCP Client (Claude / agent)
    │  Authorization: Bearer <client_token>
    ▼
┌─────────────────────────┐
│   OAuthMiddleware       │  ← Validates client_token against your IdP
│   (middleware.py)       │    Raises AuthenticationError / AuthorizationError
└─────────────────────────┘
    │  token valid
    ▼
┌─────────────────────────┐
│   Tool Handler          │  ← Business logic
└─────────────────────────┘
    │  needs upstream API
    ▼
┌─────────────────────────┐
│   TokenManager          │  ← Generates/caches server-side token for upstream
│   (auth.py)             │
└─────────────────────────┘
    │  Authorization: Bearer <server_token>
    ▼
Upstream REST API
```

---

## Full OAuthMiddleware Implementation

```python
# src/middleware.py
import logging
from typing import Any, Callable

import httpx
import jwt  # PyJWT
from fastmcp.server.middleware import Middleware, MiddlewareContext

logger = logging.getLogger(__name__)


class OAuthMiddleware(Middleware):
    """
    Validates inbound OAuth Bearer tokens on every tool call.

    Supports two validation modes (configured by OAUTH_VALIDATION_MODE):

    - "jwks"       : Validate JWT locally using the IdP's JWKS endpoint.
                     Zero network round-trip after the first call (keys cached).
                     Use for Auth0, Okta, Azure AD, Keycloak, Google, etc.

    - "introspect" : Validate opaque tokens via the IdP's introspection endpoint.
                     One network round-trip per call. Use for tokens that are
                     not JWTs or when local validation is not possible.
    """

    def __init__(self, settings: "Settings") -> None:
        self._settings = settings
        self._jwks_client: jwt.PyJWKClient | None = None

    async def on_call_tool(
        self,
        context: MiddlewareContext,
        call_next: Callable,
    ) -> Any:
        token = self._extract_token(context)
        if not token:
            raise PermissionError(
                "Missing Authorization header. "
                "Provide: Authorization: Bearer <token>"
            )
        await self._validate_token(token)
        return await call_next(context)

    # ------------------------------------------------------------------
    # Token extraction
    # ------------------------------------------------------------------

    def _extract_token(self, context: MiddlewareContext) -> str | None:
        auth_header = getattr(
            context.request, "headers", {}
        ).get("Authorization", "")
        if auth_header.startswith("Bearer "):
            return auth_header[7:]
        return None

    # ------------------------------------------------------------------
    # Validation dispatch
    # ------------------------------------------------------------------

    async def _validate_token(self, token: str) -> None:
        mode = self._settings.oauth_validation_mode
        if mode == "jwks":
            await self._validate_jwks(token)
        elif mode == "introspect":
            await self._validate_introspect(token)
        else:
            raise ValueError(f"Unknown OAUTH_VALIDATION_MODE: {mode!r}")

    # ------------------------------------------------------------------
    # JWKS validation (JWT tokens)
    # ------------------------------------------------------------------

    async def _validate_jwks(self, token: str) -> None:
        """
        Validate a JWT locally using the IdP's JWKS endpoint.
        Keys are cached for 1 hour (lifespan=3600).
        """
        if not self._jwks_client:
            self._jwks_client = jwt.PyJWKClient(
                self._settings.jwks_uri,
                cache_jwk_set=True,
                lifespan=3600,
            )
        try:
            signing_key = self._jwks_client.get_signing_key_from_jwt(token)
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256", "ES256"],
                audience=self._settings.oauth_audience,
                issuer=self._settings.oauth_issuer,
            )
            # Check required scopes if configured
            if self._settings.required_scope:
                self._check_scopes(payload, self._settings.required_scope)
            logger.debug(
                "token_validated_jwks",
                extra={"sub": payload.get("sub", "unknown")},
            )
        except jwt.ExpiredSignatureError:
            raise PermissionError("Token has expired. Request a new token.")
        except jwt.InvalidAudienceError:
            raise PermissionError(
                f"Token audience mismatch. "
                f"Expected: {self._settings.oauth_audience}"
            )
        except jwt.InvalidIssuerError:
            raise PermissionError(
                f"Token issuer mismatch. "
                f"Expected: {self._settings.oauth_issuer}"
            )
        except jwt.PyJWTError as exc:
            raise PermissionError(f"Token validation failed: {exc}")

    def _check_scopes(self, payload: dict, required: str) -> None:
        token_scopes = set(payload.get("scope", "").split())
        required_scopes = set(required.split())
        missing = required_scopes - token_scopes
        if missing:
            raise PermissionError(
                f"Token missing required scopes: {missing}"
            )

    # ------------------------------------------------------------------
    # Introspection validation (opaque tokens)
    # ------------------------------------------------------------------

    async def _validate_introspect(self, token: str) -> None:
        """
        Validate an opaque token via the IdP's introspection endpoint.
        One network round-trip per call.
        """
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                self._settings.introspection_endpoint,
                data={"token": token},
                auth=httpx.BasicAuth(
                    username=self._settings.oauth_client_id,
                    password=self._settings.oauth_client_secret,
                ),
            )
            resp.raise_for_status()
            data = resp.json()

        if not data.get("active"):
            raise PermissionError("Token is inactive or has been revoked.")

        if self._settings.required_scope:
            token_scopes = set(data.get("scope", "").split())
            required_scopes = set(self._settings.required_scope.split())
            missing = required_scopes - token_scopes
            if missing:
                raise PermissionError(
                    f"Token missing required scopes: {missing}"
                )

        logger.debug(
            "token_validated_introspect",
            extra={"sub": data.get("sub", "unknown")},
        )


class NoOpMiddleware(Middleware):
    """
    Bypass middleware for local development (DISABLE_AUTH=true).
    Never use in production.
    """

    async def on_call_tool(
        self,
        context: MiddlewareContext,
        call_next: Callable,
    ) -> Any:
        logger.warning(
            "auth_disabled",
            extra={"message": "DISABLE_AUTH=true — no token validation"},
        )
        return await call_next(context)
```

---

## Required Config Fields

```python
# src/config.py additions for inbound OAuth validation
from typing import Literal
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # ... other fields ...

    # Inbound OAuth validation
    disable_auth: bool = False
    oauth_validation_mode: Literal["jwks", "introspect"] = "jwks"

    # JWKS mode (JWT tokens — Auth0, Okta, Azure AD, Keycloak)
    jwks_uri: str = ""            # e.g., https://your-tenant.auth0.com/.well-known/jwks.json
    oauth_audience: str = ""      # e.g., https://api.your-service.com
    oauth_issuer: str = ""        # e.g., https://your-tenant.auth0.com/

    # Introspect mode (opaque tokens)
    introspection_endpoint: str = ""

    # Shared (both modes)
    required_scope: str = ""      # space-separated; empty = no scope check
```

---

## Wiring into FastMCP

```python
# src/server.py
from src.middleware import OAuthMiddleware, NoOpMiddleware
from src.config import settings

mcp = FastMCP("{service}_mcp", lifespan=lifespan)

# Register middleware based on DISABLE_AUTH env var
if settings.disable_auth:
    mcp.add_middleware(NoOpMiddleware())
else:
    mcp.add_middleware(OAuthMiddleware(settings))
```

---

## Required PyPI Packages

```toml
# pyproject.toml additions
dependencies = [
    ...
    "PyJWT[crypto]>=2.8.0",   # JWKS validation requires the [crypto] extra
    "httpx>=0.27.0",           # introspection HTTP calls
]
```

---

## .env.example Additions

```bash
# Inbound OAuth validation (for clients calling this MCP server)
DISABLE_AUTH=false
OAUTH_VALIDATION_MODE=jwks       # or "introspect"

# For JWKS mode
JWKS_URI=https://your-tenant.auth0.com/.well-known/jwks.json
OAUTH_AUDIENCE=https://api.your-service.com
OAUTH_ISSUER=https://your-tenant.auth0.com/

# For introspect mode
INTROSPECTION_ENDPOINT=https://your-idp.example.com/oauth/introspect

# Shared
REQUIRED_SCOPE=mcp:read          # leave empty to skip scope check
```

---

## Testing the Middleware

```python
# tests/test_middleware.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from src.middleware import OAuthMiddleware, NoOpMiddleware


@pytest.fixture
def settings(monkeypatch):
    from src.config import Settings
    return Settings(
        upstream_api_base_url="https://api.example.com",
        oauth_validation_mode="jwks",
        jwks_uri="https://example.auth0.com/.well-known/jwks.json",
        oauth_audience="https://api.example.com",
        oauth_issuer="https://example.auth0.com/",
        required_scope="mcp:read",
        disable_auth=False,
    )


class TestOAuthMiddleware:
    async def test_missing_header_raises(self, settings):
        middleware = OAuthMiddleware(settings)
        context = MagicMock()
        context.request.headers = {}
        call_next = AsyncMock()

        with pytest.raises(PermissionError, match="Missing Authorization"):
            await middleware.on_call_tool(context, call_next)

        call_next.assert_not_called()

    async def test_valid_token_calls_next(self, settings):
        middleware = OAuthMiddleware(settings)
        context = MagicMock()
        context.request.headers = {"Authorization": "Bearer valid-token"}
        call_next = AsyncMock(return_value="tool result")

        with patch.object(middleware, "_validate_token", AsyncMock()):
            result = await middleware.on_call_tool(context, call_next)

        assert result == "tool result"
        call_next.assert_called_once()

    async def test_expired_token_raises(self, settings):
        import jwt
        middleware = OAuthMiddleware(settings)
        context = MagicMock()
        context.request.headers = {"Authorization": "Bearer expired"}
        call_next = AsyncMock()

        with patch.object(
            middleware,
            "_validate_jwks",
            AsyncMock(side_effect=PermissionError("Token has expired")),
        ):
            with pytest.raises(PermissionError, match="expired"):
                await middleware.on_call_tool(context, call_next)

    async def test_noop_middleware_bypasses(self):
        middleware = NoOpMiddleware()
        context = MagicMock()
        call_next = AsyncMock(return_value="result")
        result = await middleware.on_call_tool(context, call_next)
        assert result == "result"
```

---

## Common IdP Configuration Reference

| IdP | JWKS URI pattern | Issuer pattern |
|-----|-----------------|----------------|
| Auth0 | `https://{tenant}.auth0.com/.well-known/jwks.json` | `https://{tenant}.auth0.com/` |
| Okta | `https://{domain}/oauth2/v1/keys` | `https://{domain}` |
| Azure AD | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys` | `https://login.microsoftonline.com/{tenant}/v2.0` |
| Keycloak | `https://{host}/realms/{realm}/protocol/openid-connect/certs` | `https://{host}/realms/{realm}` |
| Google | `https://www.googleapis.com/oauth2/v3/certs` | `https://accounts.google.com` |

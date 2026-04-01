# TDD Patterns for MCP Tools

MCP tools are pure async functions (input params → string output). This makes
them ideal for TDD. Write tests first, confirm the contract with the team, then
implement.

**Stack:** `pytest` + `pytest-asyncio` + `pytest-httpx` + `pytest-cov`

---

## Required Test Coverage per Tool

| Test Category | Required Cases |
|---------------|----------------|
| Happy path | At least 1, with full response assertion |
| Empty / null result | 1 — tool handles "nothing returned" gracefully |
| 401 Unauthorized | 1 — auth failure message is user-readable |
| 403 Forbidden | 1 — permission error message is user-readable |
| 404 Not Found | 1 (where applicable — skip for list operations) |
| 429 Rate Limited | 1 — tool surfaces retry guidance |
| 5xx Server Error | 1 — 500/502/503 upstream failure handled gracefully |
| Timeout | 1 — `httpx.TimeoutException` is caught and surfaced |
| Input validation | 1 per required field — invalid values raise `ValidationError` |
| No-op guard | 1 for update tools — empty payload returns clear error, not API call |
| Pagination | has_more=True AND has_more=False (for paginated tools) |

---

## `tests/conftest.py` Template

```python
# tests/conftest.py
import pytest
from unittest.mock import AsyncMock, MagicMock
from fastmcp import Context
from src.auth import TokenManager


# ---------------------------------------------------------------------------
# Auth fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_token_manager() -> AsyncMock:
    """
    Mocks TokenManager.get_token() to return a predictable test token.
    Prevents any network calls to the token endpoint in tests.
    """
    tm = AsyncMock(spec=TokenManager)
    tm.get_token.return_value = "test-bearer-token-abc123"
    return tm


@pytest.fixture
def mock_context(mock_token_manager: AsyncMock) -> MagicMock:
    """
    Provides a FastMCP Context mock with lifespan_state wired to
    mock_token_manager. Pass to every tool call in tests.
    """
    ctx = MagicMock(spec=Context)
    ctx.request_context.lifespan_state = {
        "token_manager": mock_token_manager,
    }
    return ctx


# ---------------------------------------------------------------------------
# Response fixtures — add one per resource
# ---------------------------------------------------------------------------

@pytest.fixture
def users_list_response() -> dict:
    return {
        "total": 2,
        "users": [
            {"id": "u1", "name": "Alice", "email": "alice@example.com", "active": True},
            {"id": "u2", "name": "Bob",   "email": "bob@example.com",   "active": True},
        ],
    }


@pytest.fixture
def single_user_response() -> dict:
    return {
        "id": "u1",
        "name": "Alice",
        "email": "alice@example.com",
        "active": True,
        "created_at": "2026-01-15T10:00:00Z",
    }
```

---

## Tool Test File Template

Replace `{resource}` with your resource name (e.g., `users`, `orders`).

```python
# tests/test_{resource}.py
import json
import pytest
import httpx
from pytest_httpx import HTTPXMock
from pydantic import ValidationError

from src.tools.{resource} import (
    list_{resource},
    get_{resource},
    create_{resource},
    List{Resource}Input,
    Get{Resource}Input,
    Create{Resource}Input,
)

BASE_URL = "https://api.example.com"  # must match Settings.upstream_api_base_url in test config


# ===========================================================================
# list_{resource}
# ===========================================================================

class TestList{Resource}:

    async def test_happy_path(
        self,
        httpx_mock: HTTPXMock,
        mock_context,
        {resource}_list_response,
    ):
        httpx_mock.add_response(
            method="GET",
            url=f"{BASE_URL}/{resource}",
            json={resource}_list_response,
            status_code=200,
        )
        result = await list_{resource}(List{Resource}Input(), mock_context)
        data = json.loads(result)
        assert data["total"] == 2
        assert len(data["{resource}"]) == 2
        assert data["{resource}"][0]["name"] == "Alice"

    async def test_empty_results(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(
            json={"total": 0, "{resource}": []},
            status_code=200,
        )
        result = await list_{resource}(List{Resource}Input(), mock_context)
        # Tool should return a user-readable "nothing found" message, not an error
        assert "no " in result.lower() or "0" in result or "empty" in result.lower()

    async def test_pagination_has_more_true(
        self,
        httpx_mock: HTTPXMock,
        mock_context,
        {resource}_list_response,
    ):
        httpx_mock.add_response(
            json={{**{resource}_list_response, "total": 100}},
            status_code=200,
        )
        result = await list_{resource}(
            List{Resource}Input(limit=2, offset=0), mock_context
        )
        data = json.loads(result)
        assert data["has_more"] is True
        assert data["next_offset"] == 2

    async def test_pagination_has_more_false(
        self,
        httpx_mock: HTTPXMock,
        mock_context,
        {resource}_list_response,
    ):
        httpx_mock.add_response(
            json={resource}_list_response,  # total=2, fetching 20
            status_code=200,
        )
        result = await list_{resource}(
            List{Resource}Input(limit=20, offset=0), mock_context
        )
        data = json.loads(result)
        assert data["has_more"] is False

    async def test_401_unauthorized(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=401)
        result = await list_{resource}(List{Resource}Input(), mock_context)
        assert "authentication" in result.lower() or "credentials" in result.lower()

    async def test_403_forbidden(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=403)
        result = await list_{resource}(List{Resource}Input(), mock_context)
        assert "permission" in result.lower() or "forbidden" in result.lower()

    async def test_429_rate_limited(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=429)
        result = await list_{resource}(List{Resource}Input(), mock_context)
        assert "rate limit" in result.lower() or "retry" in result.lower()

    async def test_5xx_server_error(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=503)
        result = await list_{resource}(List{Resource}Input(), mock_context)
        assert "error" in result.lower() or "unavailable" in result.lower()
        # Must NOT raise — tool always returns a string, never an uncaught exception

    async def test_timeout(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_exception(httpx.TimeoutException("upstream timed out"))
        result = await list_{resource}(List{Resource}Input(), mock_context)
        assert "timed out" in result.lower() or "timeout" in result.lower()

    async def test_invalid_limit_rejected(self):
        with pytest.raises(ValidationError):
            List{Resource}Input(limit=-1)

    async def test_invalid_offset_rejected(self):
        with pytest.raises(ValidationError):
            List{Resource}Input(offset=-1)


# ===========================================================================
# get_{resource}
# ===========================================================================

class TestGet{Resource}:

    async def test_happy_path(
        self,
        httpx_mock: HTTPXMock,
        mock_context,
        single_{resource}_response,
    ):
        httpx_mock.add_response(
            method="GET",
            url=f"{BASE_URL}/{resource}/u1",
            json=single_{resource}_response,
            status_code=200,
        )
        result = await get_{resource}(
            Get{Resource}Input(id="u1"), mock_context
        )
        data = json.loads(result)
        assert data["id"] == "u1"
        assert data["name"] == "Alice"

    async def test_not_found(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=404)
        result = await get_{resource}(
            Get{Resource}Input(id="nonexistent"), mock_context
        )
        assert "not found" in result.lower()

    async def test_empty_id_rejected(self):
        with pytest.raises(ValidationError):
            Get{Resource}Input(id="")

    async def test_401_unauthorized(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=401)
        result = await get_{resource}(Get{Resource}Input(id="u1"), mock_context)
        assert "authentication" in result.lower() or "credentials" in result.lower()

    async def test_timeout(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_exception(httpx.TimeoutException("timeout"))
        result = await get_{resource}(Get{Resource}Input(id="u1"), mock_context)
        assert "timed out" in result.lower() or "timeout" in result.lower()


# ===========================================================================
# create_{resource}
# ===========================================================================

class TestCreate{Resource}:

    async def test_happy_path(
        self,
        httpx_mock: HTTPXMock,
        mock_context,
        single_{resource}_response,
    ):
        httpx_mock.add_response(
            method="POST",
            url=f"{BASE_URL}/{resource}",
            json=single_{resource}_response,
            status_code=201,
        )
        result = await create_{resource}(
            Create{Resource}Input(name="Alice", email="alice@example.com"),
            mock_context,
        )
        data = json.loads(result)
        assert data["id"] == "u1"

    async def test_missing_required_field(self):
        with pytest.raises(ValidationError):
            Create{Resource}Input(name="Alice")  # email missing

    async def test_5xx_server_error(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=500)
        result = await create_{resource}(
            Create{Resource}Input(name="Alice", email="alice@example.com"),
            mock_context,
        )
        assert "error" in result.lower()

    async def test_no_fields_to_update_returns_error(self, mock_context):
        """
        update_ tools must guard against empty payloads — calling the API
        with an empty PATCH body is wasteful and some APIs treat it as an error.
        """
        result = await update_{resource}(
            Update{Resource}Input(id="u1"),  # no optional fields set
            mock_context,
        )
        assert "no fields" in result.lower() or "nothing to update" in result.lower()

    async def test_409_conflict(self, httpx_mock: HTTPXMock, mock_context):
        httpx_mock.add_response(status_code=409)
        result = await create_{resource}(
            Create{Resource}Input(name="Alice", email="alice@example.com"),
            mock_context,
        )
        assert "conflict" in result.lower() or "already exists" in result.lower()

    async def test_422_validation_error_from_api(
        self, httpx_mock: HTTPXMock, mock_context
    ):
        httpx_mock.add_response(
            status_code=422,
            json={"error": "email is invalid"},
        )
        result = await create_{resource}(
            Create{Resource}Input(name="Alice", email="not-an-email@example.com"),
            mock_context,
        )
        assert "error" in result.lower()
```

---

## pytest Configuration

```toml
# pyproject.toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
addopts = "--tb=short"
```

```bash
# Run all tests with coverage
pytest tests/ -v --cov=src --cov-report=term-missing

# Run a single test class
pytest tests/test_users.py::TestListUsers -v

# Run with specific marker
pytest tests/ -v -k "not slow"
```

---

## Key Dependencies

```toml
# pyproject.toml [project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "pytest-httpx>=0.30.0",   # HTTPXMock fixture for httpx interception
    "pytest-cov>=5.0.0",
]
```

**Why `pytest-httpx` over other mocking libraries:**
- Official companion to `httpx`
- `HTTPXMock` fixture integrates cleanly with `pytest-asyncio`
- Strict by default: raises if a registered mock is not called (prevents false passes)
- Matches by method + URL, supports regex URL matching

---

## Test Output Contract

Tool functions must return strings that satisfy:

1. **On success:** Valid JSON string (parse with `json.loads(result)`) OR a
   formatted markdown/text string. Document which format in the tool's
   `@mcp.tool(description=...)`.

2. **On error:** A human-readable `"Error: ..."` string starting with `"Error:"`.
   Never raise an uncaught exception — the MCP framework catches it, but the
   error message will be less user-friendly.

3. **On empty results:** A clear `"No {resource}s found matching your criteria."`
   string, not an empty JSON array with no explanation.

Example contract in test:
```python
# Success: parseable JSON
data = json.loads(result)
assert isinstance(data, dict)

# Error: starts with "Error:"
assert result.startswith("Error:")

# Empty: readable message
assert "no" in result.lower() or "0" in result
```

# Tool Logging

Structured logging is the primary observability mechanism for MCP servers.
Every tool must log: entry, success/failure, latency, and upstream call details.
Sensitive fields must be redacted automatically.

---

## The `log_tool_call` Decorator

Apply to every tool function. Place it **between** `@mcp.tool(...)` and
`async def` so it wraps the business logic (not the MCP registration layer).

```python
# src/logging_utils.py
import functools
import logging
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)

# Fields to redact from logged parameters (keyword-match, case-insensitive).
# Keyword-match means newly added fields named "oauth_token" or "api_secret"
# are automatically redacted without changing this decorator.
_SENSITIVE_KEYS = frozenset({
    "token", "password", "secret", "api_key", "apikey",
    "authorization", "credential", "credentials",
    "ssn", "dob", "date_of_birth", "card_number", "cvv",
})


def _sanitize(params: Any) -> dict:
    """Convert a Pydantic model or dict to a log-safe dict."""
    if hasattr(params, "model_dump"):
        raw = params.model_dump()
    elif isinstance(params, dict):
        raw = params.copy()
    else:
        return {"_raw": repr(params)[:200]}

    return {
        k: ("***REDACTED***" if any(s in k.lower() for s in _SENSITIVE_KEYS) else v)
        for k, v in raw.items()
    }


def log_tool_call(func: Callable) -> Callable:
    """
    Decorator for MCP tool handlers.

    Logs:
    - tool_call_start:   tool name + sanitized input params
    - tool_call_success: tool name + latency_ms
    - tool_call_failure: tool name + latency_ms + error_type (with exc_info)

    Does NOT log response bodies (may contain PII).

    Usage:
        @mcp.tool(name="list_users", ...)
        @log_tool_call
        async def list_users(params: ListUsersInput, ctx: Context) -> str:
            ...
    """
    @functools.wraps(func)
    async def wrapper(*args, **kwargs):
        params_repr = _sanitize(args[0]) if args else {}
        start = time.monotonic()

        logger.info(
            "tool_call_start",
            extra={"tool": func.__name__, "params": params_repr},
        )

        try:
            result = await func(*args, **kwargs)
            elapsed_ms = round((time.monotonic() - start) * 1000)
            logger.info(
                "tool_call_success",
                extra={"tool": func.__name__, "latency_ms": elapsed_ms},
            )
            return result

        except Exception as exc:
            elapsed_ms = round((time.monotonic() - start) * 1000)
            logger.error(
                "tool_call_failure",
                extra={
                    "tool": func.__name__,
                    "latency_ms": elapsed_ms,
                    "error_type": type(exc).__name__,
                },
                exc_info=True,
            )
            raise

    return wrapper
```

---

## Logging Setup

Call `setup_logging()` at server startup (top of `server.py`, before FastMCP
init).

```python
# src/logging_utils.py (continued)
import os
import json
import sys


class _JsonFormatter(logging.Formatter):
    """Emit each log record as a single-line JSON object."""

    def format(self, record: logging.LogRecord) -> str:
        log: dict = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        # Merge any extra= fields
        for key, val in record.__dict__.items():
            if key not in (
                "args", "asctime", "created", "exc_info", "exc_text",
                "filename", "funcName", "id", "levelname", "levelno",
                "lineno", "module", "msecs", "message", "msg", "name",
                "pathname", "process", "processName", "relativeCreated",
                "stack_info", "thread", "threadName",
            ):
                log[key] = val
        if record.exc_info:
            log["exc"] = self.formatException(record.exc_info)
        return json.dumps(log, default=str)


def setup_logging() -> None:
    """
    Configure root logger with JSON output to stdout.
    LOG_LEVEL env var controls verbosity (default: INFO).
    """
    level_name = os.getenv("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(_JsonFormatter())

    root = logging.getLogger()
    root.setLevel(level)
    root.handlers.clear()
    root.addHandler(handler)

    # Silence noisy third-party loggers
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
```

---

## Decorator Order

```python
# CORRECT — @log_tool_call wraps the business logic
@mcp.tool(name="list_users", description="...", annotations={...})
@log_tool_call
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    ...

# WRONG — decorators reversed; logging happens outside MCP registration
@log_tool_call
@mcp.tool(name="list_users", ...)
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    ...
```

---

## Upstream Call Logging

Add event hooks to the shared `httpx.AsyncClient` in `http_client.py` to log
every upstream request/response without per-tool boilerplate:

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
        extra={
            "status": response.status_code,
            "url": str(response.url),
        },
    )
    # Do NOT log response.text — may contain PII
```

This produces a log stream like:
```json
{"ts": "2026-03-29T10:00:00", "level": "INFO", "msg": "tool_call_start", "tool": "list_users", "params": {"limit": 20}}
{"ts": "2026-03-29T10:00:00", "level": "DEBUG", "msg": "upstream_request", "method": "GET", "url": "https://api.example.com/users?limit=20"}
{"ts": "2026-03-29T10:00:00", "level": "INFO", "msg": "upstream_response", "status": 200, "url": "https://api.example.com/users?limit=20"}
{"ts": "2026-03-29T10:00:00", "level": "INFO", "msg": "tool_call_success", "tool": "list_users", "latency_ms": 142}
```

---

## What NOT to Log

| What | Why |
|------|-----|
| Response body content | May contain PII (names, emails, SSNs) |
| Raw tokens | Security — appears in token refresh, auth headers |
| Full stack traces in user-facing errors | Leaks implementation details |
| Request body of create/update calls | May contain sensitive user data |

The `_sanitize()` function handles parameter redaction. For response content,
rely on status codes and structured metadata only.

---

## Testing the Decorator

```python
# tests/test_logging_utils.py
import pytest
import logging
from unittest.mock import AsyncMock, MagicMock
from src.logging_utils import log_tool_call, _sanitize


class TestSanitize:
    def test_redacts_password(self):
        class Params:
            def model_dump(self):
                return {"username": "alice", "password": "s3cr3t"}
        result = _sanitize(Params())
        assert result["password"] == "***REDACTED***"
        assert result["username"] == "alice"

    def test_redacts_token(self):
        result = _sanitize({"auth_token": "abc123", "name": "test"})
        assert result["auth_token"] == "***REDACTED***"
        assert result["name"] == "test"

    def test_plain_dict(self):
        result = _sanitize({"limit": 20, "offset": 0})
        assert result == {"limit": 20, "offset": 0}


class TestLogToolCall:
    async def test_logs_start_and_success(self, caplog):
        @log_tool_call
        async def my_tool(params, ctx):
            return "ok"

        with caplog.at_level(logging.INFO):
            result = await my_tool({"limit": 5}, MagicMock())

        assert result == "ok"
        messages = [r.message for r in caplog.records]
        assert any("tool_call_start" in m for m in messages)
        assert any("tool_call_success" in m for m in messages)

    async def test_logs_failure_and_reraises(self, caplog):
        @log_tool_call
        async def bad_tool(params, ctx):
            raise ValueError("boom")

        with caplog.at_level(logging.ERROR):
            with pytest.raises(ValueError, match="boom"):
                await bad_tool({}, MagicMock())

        assert any("tool_call_failure" in r.message for r in caplog.records)
```

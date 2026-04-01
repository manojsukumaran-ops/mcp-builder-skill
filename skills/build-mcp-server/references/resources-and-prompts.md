# Resources and Prompts

MCP has three primitives beyond tools. This file covers the two most useful for
enterprise servers: **Resources** (read-only browsable data) and **Prompts**
(canned workflows triggered by slash commands).

---

## When to Use Each Primitive

| Primitive | Triggered by | Use when |
|-----------|-------------|----------|
| **Tool** | LLM (Claude decides to call it) | Actions, queries with parameters, state-modifying operations |
| **Resource** | Host app (user or host browses/subscribes) | Read-only reference data, docs, catalogs, static config |
| **Prompt** | User (slash command or UI picker) | Repeatable workflows, templates, pre-loaded conversation context |

**Key distinction:** A tool is called because Claude decides it needs data. A
resource is surfaced proactively by the host as context — Claude reads it
without choosing to call anything. A prompt is invoked by the human, not Claude.

---

## Part 1: MCP Resources

### Static Resource

A fixed URI returning unchanging (or slowly changing) reference data. Good for
API documentation, field enumerations, and schema definitions.

```python
# src/resources/schema.py
import json
from src.server import mcp


@mcp.resource(
    uri="resource://schema/users",
    name="User Schema",
    description="JSON Schema for the User object, including all fields and validation rules.",
    mime_type="application/json",
)
def user_schema() -> str:
    return json.dumps({
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "properties": {
            "id":    {"type": "string"},
            "name":  {"type": "string", "maxLength": 100},
            "email": {"type": "string", "format": "email"},
            "role":  {"type": "string", "enum": ["viewer", "editor", "admin"]},
            "active": {"type": "boolean"},
        },
        "required": ["id", "name", "email"],
    })


@mcp.resource(
    uri="resource://enums/roles",
    name="Valid Roles",
    description="All valid user role values accepted by the API.",
    mime_type="text/plain",
)
def valid_roles() -> str:
    return "\n".join([
        "viewer  — read-only access to all resources",
        "editor  — can create and modify, but not delete",
        "admin   — full access including user management and deletion",
    ])
```

### Template Resource (Dynamic URI)

A URI pattern with path parameters — returns different data for each unique URI.
Good for per-entity reference pages, user profiles, or document previews.

```python
# src/resources/users.py
import json
import httpx
from src.server import mcp
from src.config import settings


@mcp.resource(
    uri="resource://users/{user_id}/profile",
    name="User Profile",
    description=(
        "Read-only profile snapshot for a user. Suitable as context when "
        "drafting communications or reviewing account history. "
        "URI example: resource://users/u123/profile"
    ),
    mime_type="application/json",
)
async def user_profile(user_id: str) -> str:
    """
    Fetch and return a user profile as a browsable resource.
    Called by the host to inject user context — not by the LLM directly.
    """
    async with httpx.AsyncClient(
        base_url=settings.upstream_api_base_url,
        headers={"Authorization": f"Bearer {settings.bearer_token}"},
        timeout=15.0,
    ) as client:
        resp = await client.get(f"/users/{user_id}")

    if resp.status_code == 404:
        return json.dumps({"error": f"User {user_id} not found."})
    resp.raise_for_status()

    raw = resp.json()
    # Return a shaped, LLM-friendly subset (see response shaping rules)
    return json.dumps({
        "id": raw["id"],
        "name": raw["displayName"],
        "email": raw["contactInfo"]["primaryEmail"],
        "role": raw["permissions"]["primaryRole"],
        "active": raw["status"] == "ACTIVE",
        "last_login": raw.get("auditInfo", {}).get("lastLoginAt"),
    }, indent=2)


@mcp.resource(
    uri="resource://orders/{order_id}/summary",
    name="Order Summary",
    description="Read-only summary of an order for use as conversation context.",
    mime_type="text/markdown",
)
async def order_summary(order_id: str) -> str:
    # Returns Markdown — more readable for LLMs than raw JSON for prose contexts
    async with httpx.AsyncClient(...) as client:
        resp = await client.get(f"/orders/{order_id}")
    resp.raise_for_status()
    o = resp.json()
    return (
        f"# Order {order_id}\n\n"
        f"**Status:** {o['status']}\n"
        f"**Customer:** {o['customer']['name']} ({o['customer']['email']})\n"
        f"**Total:** ${o['total_amount']:.2f}\n"
        f"**Items:** {len(o['line_items'])} items\n"
        f"**Created:** {o['created_at']}\n"
    )
```

### Resource List Discovery

FastMCP automatically exposes a resources/list endpoint. The host uses it to
show the user what context is available. Ensure `name` and `description` are
clear — they appear in the host's UI.

```python
# Register resources in server.py the same way as tools:
from src.resources import schema, users  # noqa: F401
```

### Resource Auth Note

Resources do not go through the `on_call_tool` middleware hook. If your
resources need auth, validate tokens directly in the resource function or use
a separate FastMCP resource middleware (if available in your FastMCP version).

For enterprise use, consider whether resources should be public (safe reference
data) or gated. If gated, add a guard at the top of each resource function:

```python
@mcp.resource("resource://sensitive/{id}/data", ...)
async def sensitive_data(id: str) -> str:
    # Manual guard — resources bypass on_call_tool middleware
    token = _get_token_from_context()  # implementation depends on FastMCP version
    if not token:
        return json.dumps({"error": "Unauthorized — resource requires authentication."})
    ...
```

### Project Layout Addition

```
src/
├── ...
└── resources/
    ├── __init__.py
    └── {resource_type}.py   ← one file per logical resource group
```

---

## Part 2: MCP Prompts

### Basic Prompt (No Arguments)

A prompt with no parameters — useful for standard workflows that need no
customization.

```python
# src/prompts/user_prompts.py
from fastmcp.prompts import UserMessage, AssistantMessage
from src.server import mcp


@mcp.prompt(
    name="onboarding-checklist",
    description="Generate an onboarding checklist for a new team member.",
)
def onboarding_checklist() -> list:
    return [
        UserMessage(
            "Generate a comprehensive onboarding checklist for a new engineer "
            "joining our team. Include: environment setup, access requests, "
            "key contacts, first-week goals, and links to important documentation. "
            "Format as a Markdown checklist."
        )
    ]
```

### Prompt with Arguments

Arguments become form fields in Claude's UI. Users fill them before the prompt
runs. Use `str` for text, `bool` for toggles.

```python
@mcp.prompt(
    name="user-activity-summary",
    description=(
        "Summarize a user's recent activity. "
        "Arguments: user_id (required), period (optional, default: last 7 days)."
    ),
)
def user_activity_summary(
    user_id: str,
    period: str = "last 7 days",
    include_errors: bool = False,
) -> list:
    """
    Args:
        user_id:        The user ID to summarize activity for.
        period:         Time period to cover (e.g., "last 7 days", "this month").
        include_errors: Whether to include failed actions in the summary.
    """
    error_instruction = (
        "Include failed/error actions with their error messages. "
        if include_errors
        else "Exclude failed actions — focus on successful operations only. "
    )
    return [
        UserMessage(
            f"Please summarize the activity for user ID `{user_id}` "
            f"over the {period}. {error_instruction}"
            f"Use the `list_user_activity` tool to fetch the data, then "
            f"present a clear, concise summary with: total actions, "
            f"most frequent operations, any notable patterns, and "
            f"any recommendations."
        )
    ]


@mcp.prompt(
    name="draft-user-communication",
    description="Draft a communication to a user based on their account status.",
)
def draft_user_communication(
    user_id: str,
    communication_type: str = "account-review",
    tone: str = "professional",
) -> list:
    """
    Args:
        user_id:             The user to draft communication for.
        communication_type:  e.g., "account-review", "welcome", "warning", "offboarding"
        tone:                e.g., "professional", "friendly", "formal"
    """
    return [
        UserMessage(
            f"Fetch the profile for user `{user_id}` using the `get_user` tool. "
            f"Then draft a {tone} {communication_type} email for this user. "
            f"The email should be personalized based on their name, role, and "
            f"account status. Include a clear subject line and sign off from "
            f"'The Platform Team'."
        )
    ]
```

### Multi-Turn Prompt (Pre-loaded Conversation Context)

Pre-load both sides of a conversation to set up complex workflows with context
already in place.

```python
@mcp.prompt(
    name="incident-investigation",
    description=(
        "Start an incident investigation workflow with context pre-loaded. "
        "Use when responding to a production alert or customer-reported issue."
    ),
)
def incident_investigation(
    incident_id: str,
    severity: str = "medium",
) -> list:
    return [
        UserMessage(
            f"I need to investigate incident {incident_id} (severity: {severity}). "
            f"Start by fetching the relevant data."
        ),
        AssistantMessage(
            f"I'll help you investigate incident {incident_id}. Let me gather "
            f"the relevant information. I'll check recent errors, affected users, "
            f"and system status."
        ),
        UserMessage(
            f"Please use the available tools to: "
            f"(1) fetch recent error logs related to this incident, "
            f"(2) identify affected users, "
            f"(3) check the current system status, "
            f"then summarize your findings and suggest next steps."
        ),
    ]
```

### Prompt Design Guidelines

| Rule | Why |
|------|-----|
| Include specific tool names in prompt text | LLM knows exactly which tools to call |
| Keep argument count ≤ 4 | More than 4 arguments makes the form unwieldy |
| Use default values liberally | Reduces friction for the common case |
| Write prompt text as if talking to Claude | It's the first `UserMessage` Claude sees |
| Name prompts as `verb-noun` kebab-case | e.g., `draft-report`, `summarize-user`, `review-order` |
| Put the "what to do" last in the prompt | Claude attends most to the end of the message |

### Project Layout Addition

```
src/
├── ...
└── prompts/
    ├── __init__.py
    └── {domain}_prompts.py   ← one file per domain (user_prompts.py, order_prompts.py)
```

Register in `server.py`:

```python
# Import to trigger @mcp.prompt registration
from src.prompts import user_prompts, order_prompts  # noqa: F401
```

---

## Part 3: Testing Prompts and Resources

### Testing Prompts

Prompts are pure functions returning `list[Message]` — easiest thing to test.
No mocks needed.

```python
# tests/test_prompts.py
from fastmcp.prompts import UserMessage, AssistantMessage
from src.prompts.user_prompts import (
    user_activity_summary,
    draft_user_communication,
    incident_investigation,
)


class TestUserActivitySummaryPrompt:

    def test_returns_user_message_list(self):
        result = user_activity_summary(user_id="u123")
        assert isinstance(result, list)
        assert len(result) >= 1
        assert all(isinstance(m, UserMessage) for m in result)

    def test_user_id_in_prompt_text(self):
        result = user_activity_summary(user_id="u123")
        combined = " ".join(m.content for m in result if isinstance(m, UserMessage))
        assert "u123" in combined

    def test_period_in_prompt_text(self):
        result = user_activity_summary(user_id="u1", period="this month")
        combined = " ".join(m.content for m in result if isinstance(m, UserMessage))
        assert "this month" in combined

    def test_error_flag_changes_instruction(self):
        with_errors = user_activity_summary(user_id="u1", include_errors=True)
        without_errors = user_activity_summary(user_id="u1", include_errors=False)
        text_with = " ".join(m.content for m in with_errors if isinstance(m, UserMessage))
        text_without = " ".join(m.content for m in without_errors if isinstance(m, UserMessage))
        assert text_with != text_without

    def test_tool_name_referenced(self):
        result = user_activity_summary(user_id="u1")
        combined = " ".join(m.content for m in result if isinstance(m, UserMessage))
        # Prompt must tell Claude which tool to use
        assert "list_user_activity" in combined or "tool" in combined.lower()


class TestIncidentInvestigationPrompt:

    def test_multi_turn_structure(self):
        result = incident_investigation(incident_id="INC-001")
        assert len(result) >= 2
        # Should have alternating user/assistant messages for context

    def test_incident_id_present(self):
        result = incident_investigation(incident_id="INC-001")
        all_text = " ".join(
            m.content for m in result
            if isinstance(m, (UserMessage, AssistantMessage))
        )
        assert "INC-001" in all_text
```

### Testing Resources

Resources are functions returning strings — also straightforward. For template
resources (dynamic URI), test with mock HTTP responses.

```python
# tests/test_resources.py
import json
import pytest
from pytest_httpx import HTTPXMock
from src.resources.schema import user_schema, valid_roles
from src.resources.users import user_profile


class TestStaticResources:

    def test_user_schema_valid_json(self):
        result = user_schema()
        data = json.loads(result)  # must be valid JSON
        assert "properties" in data
        assert "id" in data["properties"]

    def test_valid_roles_non_empty(self):
        result = valid_roles()
        assert "viewer" in result
        assert "admin" in result
        assert len(result.strip()) > 0


class TestTemplateResources:

    async def test_user_profile_happy_path(self, httpx_mock: HTTPXMock):
        httpx_mock.add_response(
            method="GET",
            url="https://api.example.com/users/u123",
            json={
                "id": "u123",
                "displayName": "Alice",
                "contactInfo": {"primaryEmail": "alice@example.com"},
                "permissions": {"primaryRole": "editor"},
                "status": "ACTIVE",
                "auditInfo": {"lastLoginAt": "2026-03-01T10:00:00Z"},
            },
        )
        result = await user_profile(user_id="u123")
        data = json.loads(result)
        assert data["id"] == "u123"
        assert data["name"] == "Alice"
        assert data["active"] is True

    async def test_user_profile_not_found(self, httpx_mock: HTTPXMock):
        httpx_mock.add_response(status_code=404)
        result = await user_profile(user_id="nonexistent")
        data = json.loads(result)
        assert "error" in data
        assert "not found" in data["error"].lower()
```

---

## Part 4: Updated `pyproject.toml` (no new deps required)

Resources and Prompts are built into FastMCP — no additional dependencies.
Just ensure your `fastmcp` version is `>=2.3.0`.

---

## Quick Reference

```python
# Register everything in server.py
from src.tools   import users, orders      # noqa: F401  — tools
from src.resources import schema, users    # noqa: F401  — resources
from src.prompts   import user_prompts     # noqa: F401  — prompts
```

```
List what's available (MCP protocol):
  tools/list       → all @mcp.tool registrations
  resources/list   → all @mcp.resource registrations
  prompts/list     → all @mcp.prompt registrations
```

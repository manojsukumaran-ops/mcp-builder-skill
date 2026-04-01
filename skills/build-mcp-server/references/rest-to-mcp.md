# REST API to MCP Conversion

Reference for converting existing REST endpoints into MCP tools. Covers tool
grouping strategy, resource-level design, and token pass-through patterns.

---

## Why 1:1 Endpoint Mapping is an Anti-Pattern

MCP tools are consumed by LLMs making semantic decisions, not programmatic
clients. A tool named `PATCH /users/{id}` forces the model to reason about HTTP
verbs and URL templates. A tool named `update_user(user_id, changes)` gives the
model semantic clarity.

Problems with 1:1 mapping:
- **Tool bloat:** 30 endpoints → 30 tools. Claude's tool selection degrades
  above ~15 tools per server; it starts picking the wrong one.
- **Verb leakage:** LLMs don't naturally think in GET/POST/PATCH/DELETE. They
  think in intent: "find", "create", "change", "remove".
- **No annotation control:** `readOnlyHint`, `destructiveHint`, `idempotentHint`
  must be set per tool. A `GET /users` and a `DELETE /users/{id}` need different
  annotations — you can't express that when they're bundled.
- **Test granularity:** One test per HTTP method is less meaningful than one
  test per business operation.

---

## The Three Grouping Strategies

### Input: Example REST Surface

```
GET    /users                 → list users (filter by active, role, search)
GET    /users/{id}            → get user by id
POST   /users                 → create user
PATCH  /users/{id}            → update user fields
DELETE /users/{id}            → hard delete user
GET    /users/{id}/roles      → list user's roles
POST   /users/{id}/roles      → assign role to user
DELETE /users/{id}/roles/{rid}→ remove role from user
```

---

### Option A — Single Action-Param Tool Per Resource

```python
manage_users(
    action: Literal[
        "list", "get", "create", "update", "delete",
        "list_roles", "assign_role", "remove_role"
    ],
    user_id: Optional[str] = None,
    role_id: Optional[str] = None,
    # ... all other fields as optional
)
```

**Pros:**
- Minimum tool count (1 per resource)
- Good for programmatic agent consumers that enumerate actions explicitly
- Works well when there are 10+ operations per resource

**Cons:**
- One massive input schema — confusing for LLMs to reason about
- Annotations (`readOnlyHint`, `destructiveHint`) cannot vary per action
- Required fields become conditional on `action`, forcing complex validation
- Harder to test individual operations in isolation

**Use when:** Primary consumer is a programmatic agent (not conversational),
or resource has more than 10 distinct operations.

---

### Option B — Read/Write Split Per Resource

```python
query_users(
    action: Literal["list", "get", "list_roles"],
    user_id: Optional[str] = None,
    # filter params...
)  # readOnlyHint=True

mutate_users(
    action: Literal["create", "update", "delete", "assign_role", "remove_role"],
    user_id: Optional[str] = None,
    # payload params...
)
```

**Pros:**
- `query_users` gets `readOnlyHint=True`, which hosts can use to show read-only
  indicators
- Moderate tool count (2 per resource)
- Clear safety boundary between reads and writes

**Cons:**
- LLM must first decide "is this a read or a write?" before selecting a tool
- Action-param problem remains within each half
- `delete` and `assign_role` have very different risk profiles but share a tool

**Use when:** Separation of read vs. write access is a hard compliance
requirement, or when you want to expose read-only tools to a wider audience.

---

### Option C — Semantic Operations (Recommended)

```python
list_users(filters, pagination)         # readOnlyHint=True
get_user(user_id)                       # readOnlyHint=True
create_user(profile)                    # idempotentHint=False
update_user(user_id, changes)           # idempotentHint=True
deactivate_user(user_id, reason)        # destructiveHint=True — named by intent
list_user_roles(user_id)               # readOnlyHint=True
assign_user_role(user_id, role)        # idempotentHint=True
revoke_user_role(user_id, role_id)     # destructiveHint=True
```

**Pros:**
- Crystal-clear natural-language names LLMs understand immediately
- Each tool has precise, independent annotations
- Each tool tested in complete isolation — cleaner test suite
- Tool descriptions can be tailored per operation
- `deactivate_user` vs. `delete_user` signals intent; LLMs less likely to call
  the wrong one accidentally
- Acceptable up to ~15 tools per server

**Cons:**
- More tools in the registry (mitigated by staying under ~15)
- More files to generate

**Use when:** Primary consumer is a conversational LLM (Claude), or operations
have meaningfully different risk profiles, required fields, or scopes.

---

## Decision Guide

| Factor | Option A | Option B | Option C |
|--------|----------|----------|----------|
| Primary consumer is conversational LLM | | | ✓ |
| Primary consumer is programmatic agent | ✓ | ✓ | |
| 10+ operations per resource | ✓ | | |
| Need `readOnlyHint` separation for compliance | | ✓ | ✓ |
| < 5 operations per resource | | | ✓ |
| Operations have different required fields | | | ✓ |
| Operations have different risk profiles | | | ✓ |
| Tools per server approaching 15 | ✓ | ✓ | |

**Default: Option C.** Ask the user to confirm or switch before generating code.

---

## Endpoint Prioritization Table

Use this table in Phase 1 to determine what to scaffold:

```
Endpoint                      | Priority | Tool Name (proposed)
-----------------------------|----------|---------------------
GET  /users                  | 1        | list_users
GET  /users/{id}             | 1        | get_user
POST /users                  | 1        | create_user
PATCH /users/{id}            | 1        | update_user
DELETE /users/{id}           | 2        | deactivate_user
GET  /users/{id}/roles       | 1        | list_user_roles
POST /users/{id}/roles       | 2        | assign_user_role
DELETE /users/{id}/roles/{r} | X        | (excluded — admin only)
```

Priority 1: scaffold immediately.
Priority 2: scaffold with a TODO stub.
X: skip.

---

## Token Pass-Through Pattern

When the MCP tool calls the upstream REST API, the OAuth token comes from the
server-side `TokenManager` (not from the MCP client's token). The flow:

```
MCP Client presents → OAuthMiddleware validates inbound token
                                     ↓
                          Tool handler runs
                                     ↓
                    TokenManager.get_token() → cached or refreshed server token
                                     ↓
                    Upstream REST API called with server token
```

The `TokenManager` is stored in FastMCP's lifespan state and accessed per-call:

```python
# In every tool handler — never use a global token variable
@mcp.tool(name="list_users", ...)
@log_tool_call
async def list_users(params: ListUsersInput, ctx: Context) -> str:
    # Step 1: Get the outbound token from lifespan state
    token_manager: TokenManager = ctx.request_context.lifespan_state["token_manager"]
    token = await token_manager.get_token()

    # Step 2: Call upstream API with the token
    try:
        async with get_client(token) as client:
            resp = await client.get("/users", params=params.model_dump(exclude_none=True))
    except httpx.TimeoutException:
        return "Error: Request timed out."

    if not resp.is_success:
        return _handle_api_error(resp)

    return json.dumps(resp.json())
```

**Why lifespan state, not a global:**
- Thread-safe — each request gets the same manager but `get_token()` uses
  asyncio.Lock internally
- Testable — mock_context in tests provides a mock token manager
- No import-time side effects — TokenManager is not initialized until the
  lifespan starts

---

## Pagination: Cursor vs Offset

Many modern APIs use **cursor-based pagination** instead of offset. The tool
design and test fixtures differ significantly — identify which type during
Phase 1 and design accordingly.

### Offset Pagination

The API accepts `limit` + `offset` (or `page` + `per_page`). Simple but can
miss items if the dataset changes between pages.

```python
class ListUsersInput(BaseModel):
    limit: int = Field(20, ge=1, le=100)
    offset: int = Field(0, ge=0)

# Response shape
{
    "users": [...],
    "total": 847,
    "has_more": true,
    "next_offset": 20
}
```

### Cursor-Based Pagination

The API returns an opaque `next_cursor` token. The client passes it back on the
next call. Cannot seek to an arbitrary page, but handles live data correctly.

```python
class ListUsersInput(BaseModel):
    limit: int = Field(20, ge=1, le=100)
    cursor: Optional[str] = Field(
        None,
        description="Pagination cursor from a previous response. "
                    "Omit for the first page."
    )

# Response shape
{
    "users": [...],
    "has_more": true,
    "next_cursor": "eyJpZCI6IjEwMCJ9"   # opaque — do not parse
}
```

**Tool description must tell the LLM how to paginate:**

```python
@mcp.tool(
    name="list_users",
    description=(
        "List users. Returns up to `limit` results. "
        "If `has_more` is true, call again with the returned `next_cursor` "
        "to fetch the next page. Omit `cursor` for the first page."
    ),
    ...
)
```

### How to Identify Which Type the API Uses

Ask in Phase 1 Batch B (or inspect the OpenAPI spec):

> "Does your API use offset/page-number pagination or cursor-based pagination?
> If cursor-based, what is the response field name for the next-page token?
> (Common names: `next_cursor`, `cursor`, `next_page_token`, `continuation_token`)"

### Test Differences for Cursor Pagination

```python
async def test_pagination_has_more_true_cursor(
    self, httpx_mock: HTTPXMock, mock_context
):
    httpx_mock.add_response(
        json={
            "users": [{"id": "u1"}, {"id": "u2"}],
            "has_more": True,
            "next_cursor": "abc123",
        }
    )
    result = await list_users(ListUsersInput(limit=2), mock_context)
    data = json.loads(result)
    assert data["has_more"] is True
    assert data["next_cursor"] == "abc123"


async def test_pagination_last_page_cursor(
    self, httpx_mock: HTTPXMock, mock_context
):
    httpx_mock.add_response(
        json={
            "users": [{"id": "u99"}],
            "has_more": False,
            "next_cursor": None,
        }
    )
    result = await list_users(ListUsersInput(cursor="abc123"), mock_context)
    data = json.loads(result)
    assert data["has_more"] is False
    assert data.get("next_cursor") is None
```

---

## Mapping HTTP Verbs to Tool Names

| HTTP Method | REST convention | Preferred MCP tool name |
|-------------|----------------|------------------------|
| GET (collection) | list/search | `list_{resource}`, `search_{resource}` |
| GET (item) | fetch by id | `get_{resource}` |
| POST | create | `create_{resource}` |
| PUT | replace | `replace_{resource}` |
| PATCH | partial update | `update_{resource}` |
| DELETE (soft) | deactivate | `deactivate_{resource}`, `archive_{resource}` |
| DELETE (hard) | hard delete | `delete_{resource}` — add `destructiveHint=True` |
| POST /action | custom action | name the action directly: `approve_order`, `cancel_subscription` |

---

## Sub-Resource Handling

When endpoints involve sub-resources (e.g., `/users/{id}/roles`), you have
two choices:

**Option 1: Include in parent resource's tool file** (recommended when sub-
resource has < 3 operations)

```python
# src/tools/users.py — include list_user_roles, assign_user_role here
@mcp.tool(name="list_user_roles", ...)
@log_tool_call
async def list_user_roles(params: ListUserRolesInput, ctx: Context) -> str:
    ...
```

**Option 2: Separate tool file** (when sub-resource has its own CRUD surface)

```python
# src/tools/roles.py — own file when roles have their own management
@mcp.tool(name="list_roles", ...)     # global roles catalog
@mcp.tool(name="get_role", ...)
@mcp.tool(name="assign_role_to_user", ...)
```

---

## Handling OpenAPI Specs

When the user provides an OpenAPI spec URL or YAML/JSON:

1. Parse paths and group by first path segment (the resource):
   - `/users/*` → users resource
   - `/orders/*` → orders resource
   - `/orders/{id}/items/*` → items sub-resource under orders

2. For each resource, list the operations and ask which priority tier.

3. Map each operation to a semantic tool name using the verb table above.

4. Note any operations with no obvious semantic name — ask the user.

5. Identify shared input parameters across operations on the same resource
   (e.g., `user_id` appears in 5 different paths) — these become the Pydantic
   model fields.

---

## Naming Conventions

| Pattern | Example |
|---------|---------|
| List | `list_users`, `search_orders` |
| Get single | `get_user`, `get_order` |
| Create | `create_user`, `submit_order` |
| Update | `update_user`, `modify_order` |
| Soft delete / deactivate | `deactivate_user`, `cancel_order`, `archive_project` |
| Hard delete | `delete_user` (add `destructiveHint=True`) |
| Custom action | `approve_invoice`, `publish_post`, `resend_email` |
| Sub-resource list | `list_user_roles`, `get_order_items` |
| Sub-resource mutate | `assign_user_role`, `add_order_item`, `remove_order_item` |

Use snake_case. Avoid: `do_`, `perform_`, `execute_`, HTTP verbs in names,
URL fragments.

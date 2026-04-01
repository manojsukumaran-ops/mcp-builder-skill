# MCP Builder

A Claude Code skill that guides enterprise teams through building
production-ready MCP (Model Context Protocol) servers using FastMCP (Python).

---

## What It Does

Invoke `/build-mcp-server` in Claude Code or Cursor to start an interactive
session that takes you through:

1. **Mode selection** — build a new server from scratch, or convert an existing REST API
2. **Clarifying questions** — service identity, auth method, transport, deployment target
3. **Tool architecture design** — confirms tool grouping before any code is generated
4. **TDD scaffold** — generates tests first; waits for your review before writing implementation
5. **Full implementation** — generates all source files, configs, Docker, Kubernetes, and CI/CD

### What Gets Generated

| Area | Output |
|------|--------|
| Core server | `pyproject.toml`, `src/server.py`, `src/config.py` |
| Auth | `src/auth.py` (outbound TokenManager), `src/middleware.py` (inbound OAuth) |
| Tools | `src/tools/{resource}.py` per resource group |
| Resources & Prompts | `src/resources/`, `src/prompts/` (if applicable) |
| Tests | `tests/conftest.py`, `tests/test_{resource}.py` |
| Deployment | `Dockerfile`, `docker-compose.yml`, `k8s/`, `.gitlab-ci.yml` |
| Config | `.env.example`, `README.md` |

---

## Prerequisites

- **Claude Code** CLI or Desktop app — [install guide](https://docs.anthropic.com/en/docs/claude-code)
- **OR** Cursor IDE — [cursor.com](https://www.cursor.com)
- `bash` (macOS or Linux)

---

## Install

Clone the repository and run the installer:

```bash
git clone <this-repo-url>
cd mcp-builder
./install.sh
```

This installs the skill at the **user level** — available in every session,
no per-project setup required.

### Install options

```bash
./install.sh                  # Install for both Claude Code and Cursor (default)
./install.sh --claude-only    # Claude Code only
./install.sh --cursor-only    # Cursor IDE only
./install.sh --symlink        # Symlink source instead of copying (dev/contributor mode)
./install.sh --uninstall      # Remove from both IDEs
./install.sh --help           # Show all options
```

### Install locations

| IDE | Location |
|-----|----------|
| Claude Code | `~/.claude/skills/build-mcp-server/` |
| Cursor | `~/.cursor/rules/build-mcp-server.mdc` |

---

## Usage

### Claude Code

Open any Claude Code session and type:

```
/build-mcp-server
```

Claude will guide you through the phases interactively.

### Cursor

In the Cursor chat panel:

1. Type `@build-mcp-server` to reference the rule, or
2. Go to **Settings → Rules for AI** and enable `build-mcp-server`

Then ask Claude to help you build an MCP server.

---

## Updating

Pull the latest changes and re-run the installer:

```bash
git pull
./install.sh
```

The installer backs up any existing installation before overwriting
(e.g. `build-mcp-server.bak.20260101_120000`).

**For contributors / skill developers:** use `--symlink` so edits to
`skills/build-mcp-server/` propagate to Claude Code immediately without
reinstalling. Re-run without `--symlink` after editing reference files to
regenerate the Cursor `.mdc`.

---

## Repository Structure

```
mcp-builder/
├── install.sh                         ← installer script
└── skills/
    └── build-mcp-server/
        ├── SKILL.md                   ← main skill (5-phase guide)
        ├── references/
        │   ├── auth-patterns.md       ← 7 outbound auth methods + TokenManager
        │   ├── deployment-k8s-gitlab.md ← Docker, Kubernetes, GitLab CI/CD guide
        │   ├── oauth-middleware.md    ← inbound OAuth validation middleware
        │   ├── resources-and-prompts.md ← MCP Resources and Prompts patterns
        │   ├── rest-to-mcp.md         ← REST API → MCP tool conversion patterns
        │   ├── scaffold-fastmcp.md    ← full FastMCP project scaffold
        │   ├── tdd-patterns.md        ← pytest + pytest-httpx TDD patterns
        │   └── tool-logging.md        ← log_tool_call decorator + structured logging
        └── assets/
            ├── Dockerfile             ← multi-stage build template
            ├── .dockerignore
            ├── docker-compose.yml     ← local dev template
            ├── .gitlab-ci.yml         ← CI/CD pipeline template
            └── k8s/
                ├── configmap.yaml
                ├── deployment.yaml
                ├── service.yaml
                ├── hpa.yaml
                └── ingress.yaml
```

---

## Uninstall

```bash
./install.sh --uninstall
```

Removes `~/.claude/skills/build-mcp-server/` and `~/.cursor/rules/build-mcp-server.mdc`.

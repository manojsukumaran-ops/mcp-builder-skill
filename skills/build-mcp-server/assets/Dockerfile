# ── Stage 1: Install dependencies ─────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build
RUN pip install --no-cache-dir --upgrade pip

# Copy manifest and source so hatchling can build the package
COPY pyproject.toml .
COPY src/ src/

# Install to a prefix directory for clean copying into the runtime image
RUN pip install --no-cache-dir --prefix=/runtime .

# ── Stage 2: Runtime ──────────────────────────────────────────────────────
FROM python:3.11-slim

# Non-root user — UID/GID 1001 avoids conflicts with common system accounts
RUN groupadd --gid 1001 mcpuser \
 && useradd --uid 1001 --gid mcpuser --shell /bin/sh --create-home mcpuser

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /runtime/lib /usr/local/lib
COPY --from=builder /runtime/bin /usr/local/bin

# Copy application source (needed by `fastmcp run src/server.py`)
COPY --chown=mcpuser:mcpuser src/ src/

USER mcpuser

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    LOG_LEVEL=INFO

EXPOSE 8000

# All secrets must be injected via environment variables at runtime.
# Never bake .env into the image.
CMD ["fastmcp", "run", "src/server.py", \
     "--transport", "streamable-http", \
     "--port", "8000", \
     "--host", "0.0.0.0"]

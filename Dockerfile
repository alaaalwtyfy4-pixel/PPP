# =============================================================================
# Agency Marketing OS — Multi-Stage Production Dockerfile (Render)
# =============================================================================

# ---- Builder Stage ----
FROM python:3.11-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir -r requirements.txt

# ---- Runtime Stage ----
FROM python:3.11-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 curl && rm -rf /var/lib/apt/lists/*
RUN groupadd -r appuser && useradd -r -g appuser -d /workspace -s /sbin/nologin appuser
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# PYTHONPATH=/workspace tells Python to look in /workspace for packages.
# The project structure inside the container is /workspace/app/main.py,
# so `from app.core.config import ...` resolves to /workspace/app/core/config.py
ENV PYTHONPATH=/workspace

WORKDIR /workspace
COPY --chown=appuser:appuser . .
RUN mkdir -p /workspace/logs && chown -R appuser:appuser /workspace
USER appuser
EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4", "--proxy-headers", "--forwarded-allow-ips", "*"]

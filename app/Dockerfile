# ── Stage 1: dependency builder ──────────────────────────────────────────────
# Pin the base image to a specific minor so rebuilds are reproducible.
FROM python:3.11-slim AS builder

WORKDIR /build

# Copy only the dependency file first so Docker cache layer is reused
# when only source code changes (not requirements).
COPY requirements.txt .

# Install into a local prefix so we can copy the tree to the final image
# without carrying pip/wheel cache.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.11-slim

# Create a non-root user (UID 1000) — never run app code as root.
RUN addgroup --system appgroup && adduser --system --ingroup appgroup --uid 1000 appuser

WORKDIR /app

# Copy pre-built packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY --chown=appuser:appgroup . .

# Drop privileges before the process starts
USER appuser

# Expose the port gunicorn will bind to
EXPOSE 5000

# 2 workers is appropriate for 2-core hardware with 256 MB memory limit.
# --access-logfile - sends access logs to stdout (captured by Kubernetes).
CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:5000", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "main:app"]

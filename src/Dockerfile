# ==============================================================================
# Description: Multi-stage Dockerfile for the health check service (builder + runtime) using Alpine Linux for minimal image size (<100MB).
# Author: implementer
# Usage: docker build -t gh-actions-auto-rollback src/
# Env Variables: PORT (default: 8080)
# Dependencies: Docker
# ==============================================================================
# syntax=docker/dockerfile:1.4

# Builder stage - install dependencies only
FROM python:3.12-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    libffi-dev \
    musl-dev

# Set working directory
WORKDIR /app

# Copy dependency files
COPY pyproject.toml requirements.txt ./

# Install dependencies to a virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Runtime stage - minimal image
FROM python:3.12-alpine AS runtime

# Create non-root user (UID 10001)
RUN addgroup -g 10001 appgroup && \
    adduser -u 10001 -G appgroup -s /bin/bash -D appuser

# Install curl for health check
RUN apk add --no-cache curl

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set working directory
WORKDIR /app

# Copy application code
COPY --chown=appuser:appgroup app/ ./app/

# Switch to non-root user
USER appuser

# Expose port and set PORT environment variable
EXPOSE 8080
ENV PORT=8080

# Health check (interval=30s, timeout=3s, start-period=5s, retries=3)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run the application
CMD ["python", "-m", "app.main"]
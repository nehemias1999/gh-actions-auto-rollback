# Agent Contract: REQ-1 Python Health Check Application

## Spec Reference
- **Capability**: `ci-pipeline` (Docker build requirement) + `health-check` (endpoint requirement)
- **Spec Files**: 
  - `/home/nsalazar/Documents/Projects/gh-actions-auto-rollback/openspec/specs/ci-pipeline/spec.md` (Requirement: "The system SHALL build a Docker image from the project Dockerfile")
  - `/home/nsalazar/Documents/Projects/gh-actions-auto-rollback/openspec/specs/health-check/spec.md` (Requirement: "The system SHALL verify the health endpoint returns the expected response")

## Allowed Files (PERMITIDOS)
- `src/app/main.py`
- `src/app/__init__.py`
- `src/tests/test_health.py`
- `src/pyproject.toml`
- `src/requirements.txt`
- `src/Dockerfile`
- `src/.dockerignore`

## Forbidden (NUNCA)
- `openspec/` (specs)
- `.github/workflows/` (other workflows)
- `scripts/` (deployment scripts)
- `tests/` (integration tests, bats tests)
- Any file not listed in PERMITIDOS

## Interface/API Contract
**Application**: FastAPI app in `src/app/main.py`
- **Endpoint**: `GET /health`
- **Response**: HTTP 200, JSON `{"status": "healthy"}` within 100ms
- **Port**: Configurable via `PORT` environment variable (default 8080)
- **Graceful shutdown**: Handle SIGTERM for zero-downtime deployments
- **Logging**: Startup message with version and port

**Docker Image**: 
- Multi-stage build (builder + runtime)
- Python 3.12 slim base
- Non-root user (UID 10001)
- Exposes port 8080
- HEALTHCHECK configured: `curl -f http://localhost:8080/health || exit 1`
- Image size < 100MB

## Project Profile: Python Application
**Verification Commands**:
```bash
# Unit tests with coverage
cd src && python -m pytest tests/ -v --cov=app --cov-report=term-missing

# Linting
cd src && ruff check app/ tests/

# Type checking
cd src && mypy app/

# Docker build
docker build -t gh-actions-auto-rollback:test src/

# Docker health check
docker run --rm -d --name test-app -p 8080:8080 gh-actions-auto-rollback:test
sleep 5
curl -f http://localhost:8080/health
docker stop test-app
```

## Definition of Done (Verificable)
- [ ] All pytest tests pass with ≥80% coverage on `app` module
- [ ] `ruff check` passes with zero violations
- [ ] `mypy` passes with zero errors
- [ ] Docker image builds successfully
- [ ] Docker image size < 100MB
- [ ] Container starts and responds to `/health` within 5 seconds
- [ ] HEALTHCHECK in Dockerfile passes
- [ ] Code documented per `code-doc-standard` (purpose, args, env vars, examples)

## Implementer Report Format
Return `DONE|BLOCKED|NEEDS_CONTEXT` with evidence:
- Test output (pytest, ruff, mypy)
- Docker build output
- Health check curl output
- `docker images` size output
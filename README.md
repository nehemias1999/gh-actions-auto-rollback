# gh-actions-auto-rollback

Automated deployment pipeline via GitHub Actions: semantic versioning, blue/green container deploys, and healthcheck-triggered automatic rollbacks for zero-downtime operations.

[![CI](https://github.com/nehemias1999/gh-actions-auto-rollback/actions/workflows/ci.yml/badge.svg)](https://github.com/nehemias1999/gh-actions-auto-rollback/actions/workflows/ci.yml)

## Table of Contents

- [Background](#background)
- [Install](#install)
- [Usage](#usage)
- [API / Configuration](#api--configuration)
- [Contributing](#contributing)

## Background

Every deployment to production risks shipping broken code. This project answers one question: *what happens when the new version fails its health check?* Instead of leaving a broken container serving traffic, the pipeline stages the new version beside the live one, probes it, and either promotes it or automatically rolls back to the previous version — all in GitHub Actions with plain Docker CLI and Bash, no Kubernetes required.

Unlike a basic "build and run" workflow, each deploy is a guarded blue/green rotation: the new container must prove itself healthy before it receives traffic, and any failure restores the old container and re-verifies it.

### Technologies

- **App**: Python 3.12, FastAPI, Uvicorn (`src/`)
- **Runtime**: Docker, multi-stage Alpine image with non-root user and `HEALTHCHECK`
- **CI/CD**: GitHub Actions (CI on `pull_request`, deploy on `push` to `main`), semantic-release (Angular preset, Conventional Commits)
- **Scripts**: Bash (`scripts/`), tested with [bats](https://github.com/bats-core/bats-core)
- **Local pipeline emulation**: [act](https://github.com/nektos/act) (`tests/integration.sh`)

Requirements and acceptance criteria live in [`openspec/`](openspec/) (specs: `ci-pipeline`, `blue-green-deploy`, `health-check`, `auto-rollback`, `semantic-release`, `integration-testing`).

### Architecture / Flow

```
push to main
  └─ Deploy workflow: semantic-release → version tag (vX.Y.Z + latest)
       └─ docker build src/
            └─ scripts/deploy.sh --version <semver> --image <name>
                 ├─ detect active port (probe 8080, then 8081 via healthcheck.sh)
                 ├─ start app-<ver>-staging on staging port
                 ├─ healthcheck.sh --url http://localhost:<staging>/health
                 │    ├─ healthy → stop old, rename staging → app-<ver>-active, write /tmp/active-port
                 │    └─ failing → rollback.sh (remove new, restore + re-check old), exit non-zero
```

Components:

| Component | Files |
|---|---|
| Python Health App — FastAPI, `GET /health` → `{"status": "healthy"}`, `PORT` env, SIGTERM handling | `src/app/main.py`, `src/tests/test_health.py` |
| Container image — multi-stage Alpine, UID 10001, `HEALTHCHECK`, listens on 8080 | `src/Dockerfile`, `src/.dockerignore` |
| CI workflow — lint (ruff), typecheck (mypy), test (pytest + coverage gate), docker build, health check | `.github/workflows/ci.yml` |
| Deploy workflow — semantic-release, build, `deploy.sh`, exposes `deployed-version` output | `.github/workflows/deploy-prod.yml` |
| Scripts — `deploy.sh`, `healthcheck.sh`, `rollback.sh` (exit codes 0/1/2, timestamped logs) | `scripts/` |
| Integration tests — `act` scenarios for CI, healthy deploy, and rollback | `tests/integration.sh` |

## Install

Prerequisites (exact, reproducible):

- Docker ≥ 24 with a running daemon
- Python ≥ 3.12 with `pip`
- Bash + `curl`
- Optional for local verification: [`act`](https://github.com/nektos/act#installation), [`bats`](https://github.com/bats-core/bats-core), `yamllint`, `shellcheck`

```bash
git clone https://github.com/nehemias1999/gh-actions-auto-rollback.git
cd gh-actions-auto-rollback

# Python dev dependencies (app + lint + typecheck + tests)
pip install -r src/requirements.txt
pip install "pytest>=8.2.0" "pytest-cov>=5.0.0" "httpx>=0.27.0" "ruff>=0.5.0" "mypy>=1.10.0"

# Build the image (context is src/)
docker build -t gh-actions-auto-rollback:local src/
```

## Usage

Happy path — ship a version (triggers automatically on push to `main` with a Conventional Commit message):

```bash
git commit -m "feat: add readiness probe"
git push origin main
# Deploy workflow: semantic-release tags vX.Y.Z → builds image → blue/green deploy → healthcheck → promote or auto-rollback
```

Run the app locally:

```bash
docker run -d --name app-local -p 8080:8080 gh-actions-auto-rollback:local
curl -f http://localhost:8080/health   # {"status": "healthy"}
```

Deploy manually with the script (same command the workflow runs):

```bash
./scripts/deploy.sh --version v1.3.0 --image gh-actions-auto-rollback:v1.3.0
./scripts/deploy.sh --version v1.3.0 --image gh-actions-auto-rollback:v1.3.0 --current-port 8080 --staging-port 8081
```

Probe and roll back manually:

```bash
./scripts/healthcheck.sh --url http://localhost:8080/health --retries 10 --interval 3 --timeout 2
./scripts/rollback.sh --new-container app-v1.3.0-staging --old-container app-v1.2.0-active --health-url http://localhost:8080/health
```

## API / Configuration

App endpoint:

| Endpoint | Response |
|---|---|
| `GET /health` | `200 OK`, body `{"status": "healthy"}` |

Environment variables:

| Variable | Used by | Default | Format |
|---|---|---|---|
| `PORT` | Python app (`src/app/main.py`) | `8080` | TCP port number |
| `ACT_SECRETS_FILE` | `tests/integration.sh` | `.secrets.local` | Path to act `--secret-file` (copy `.secrets.local.example`, git-ignored) |
| `DOCKER_BIN` | `tests/integration.sh` | `docker` | Docker binary path override |
| `PYTHON_VERSION` | CI workflow | `3.12` | Workflow env, informational |
| `DOCKER_IMAGE` | CI / deploy workflows | `gh-actions-auto-rollback` | Image name (deploy tags `<semver>` + `latest`; CI tags `pr-<number>`) |
| `APP_PATH` | CI / deploy workflows | `src` | Docker build context |

Script flags (all scripts: `-h/--help` prints usage to STDOUT, exit 0; exit codes 0 success / 1 runtime failure / 2 usage error):

| Script | Required flags | Optional flags (defaults) |
|---|---|---|
| `scripts/deploy.sh` | `--version <semver>`, `--image <name>` | `--current-port` (8080), `--staging-port` (8081) |
| `scripts/healthcheck.sh` | `--url <endpoint>` | `--retries` (10), `--interval` (3s), `--timeout` (2s) |
| `scripts/rollback.sh` | `--new-container`, `--old-container`, `--health-url` | `--retries` (10), `--interval` (3s), `--timeout` (2s) |
| `tests/integration.sh` | — | positional `ci \| deploy-success \| deploy-rollback` (none = all three) |

## Contributing

Local development setup: see [Install](#install). The `main` branch is protected by the CI workflow — every pull request runs lint, typecheck, tests with coverage gate, image build, and container health check.

Run the verification suite before pushing:

```bash
# Python unit tests (from repo root; pytest reads src/pyproject.toml)
cd src && pytest
cd src && ruff check . && mypy app

# Bash unit tests
bats tests/

# Workflow lint
yamllint .github/workflows/ci.yml .github/workflows/deploy-prod.yml

# Spec validation
openspec validate --all
```

Integration tests — full pipeline locally with [`act`](https://github.com/nektos/act#installation):

```bash
./tests/integration.sh                  # all scenarios
./tests/integration.sh ci               # CI workflow (act pull_request)
./tests/integration.sh deploy-success   # healthy deploy (act push)
./tests/integration.sh deploy-rollback  # unhealthy deploy, expects rollback
```

Each scenario runs in its own isolated Docker network and all test containers/networks are removed afterwards. Secrets: copy `.secrets.local.example` to `.secrets.local` (git-ignored) and fill in `GH_TOKEN` — never commit real tokens (`.secrets.local*` besides the example is ignored). If `act` is not installed the script prints a skip message with the install pointer and exits 0.

Commit convention: [Conventional Commits](https://www.conventionalcommits.org/) (Angular preset) — `feat:`, `fix:`, `docs:`, etc. `feat` and `fix` drive semantic versioning on push to `main`.

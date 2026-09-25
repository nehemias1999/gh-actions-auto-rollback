# gh-actions-auto-rollback
Automated deployment workflow via GitHub Actions. Implements semantic versioning, container deployment, and healthcheck-triggered rollbacks for zero-downtime operations.

## Integration tests

Run the full pipeline (CI + deploy + healthcheck + rollback) locally with [`act`](https://github.com/nektos/act#installation):

```bash
./tests/integration.sh                  # all scenarios
./tests/integration.sh ci               # CI workflow (act pull_request)
./tests/integration.sh deploy-success   # healthy deploy (act push)
./tests/integration.sh deploy-rollback  # unhealthy deploy, expects rollback
./tests/integration.sh --help           # usage
```

Each scenario runs in its own isolated Docker network and all test
containers/networks are removed afterwards. Secrets: copy
`.secrets.local.example` to `.secrets.local` (git-ignored) and fill in
`GH_TOKEN`. If `act` is not installed the script prints a skip message
with the install pointer and exits 0.

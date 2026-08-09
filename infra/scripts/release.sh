#!/usr/bin/env bash
set -Eeuo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose_files=(-f "$repository_dir/infra/compose.yml")

cd "$repository_dir"

if [[ ! -f .env ]]; then
  echo "Missing .env; refusing release." >&2
  exit 1
fi

docker compose "${compose_files[@]}" config --quiet
docker compose "${compose_files[@]}" build --pull api worker beat

if [[ "${PROJECT_LEDGER_SKIP_BACKUP:-false}" != "true" ]]; then
  "$repository_dir/infra/backup/backup.sh"
fi

docker compose "${compose_files[@]}" run --rm api python manage.py check --deploy
docker compose "${compose_files[@]}" run --rm api python manage.py migrate --plan

echo "Review the migration plan above. Set PROJECT_LEDGER_APPLY_RELEASE=yes to continue."
if [[ "${PROJECT_LEDGER_APPLY_RELEASE:-no}" != "yes" ]]; then
  exit 2
fi

docker compose "${compose_files[@]}" run --rm api python manage.py migrate --noinput
docker compose "${compose_files[@]}" run --rm api python manage.py collectstatic --noinput
docker compose "${compose_files[@]}" up -d --remove-orphans

for attempt in {1..30}; do
  if curl --fail --silent --show-error http://127.0.0.1:"${PROJECT_LEDGER_LOOPBACK_PORT:-8080}"/api/v1/health/ready >/dev/null; then
    docker compose "${compose_files[@]}" ps
    echo "Release health verification passed."
    exit 0
  fi
  sleep 2
done

echo "Release did not become healthy. Keep the pre-release backup and follow infra/RUNBOOK.md rollback guidance." >&2
docker compose "${compose_files[@]}" ps >&2
exit 1


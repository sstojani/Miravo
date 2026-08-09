#!/usr/bin/env bash
set -Eeuo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
backup_root="${PROJECT_LEDGER_BACKUP_ROOT:-/var/backups/projectledger}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging_dir="$(mktemp -d "$backup_root/.staging-${timestamp}-XXXXXX")"
final_archive="$backup_root/project-ledger-${timestamp}.tar.gz.age"

cleanup() {
  if [[ "$staging_dir" == "$backup_root"/.staging-* && -d "$staging_dir" ]]; then
    rm -rf -- "$staging_dir"
  fi
}
trap cleanup EXIT

if [[ -z "${PROJECT_LEDGER_BACKUP_AGE_RECIPIENT:-}" ]]; then
  echo "PROJECT_LEDGER_BACKUP_AGE_RECIPIENT is required; plaintext backups are refused." >&2
  exit 1
fi
command -v age >/dev/null
command -v docker >/dev/null

cd "$repository_dir"
docker compose -f infra/compose.yml exec -T postgres \
  pg_dump --format=custom --no-owner --no-acl \
  --username="${POSTGRES_USER:-projectledger}" "${POSTGRES_DB:-projectledger}" \
  >"$staging_dir/database.dump"

docker run --rm \
  -v project-ledger_private_media:/source:ro \
  -v "$staging_dir:/backup" \
  alpine:3.22.1 \
  tar -C /source -czf /backup/private-media.tar.gz .

cp .env.example "$staging_dir/env-inventory.example"
git rev-parse HEAD >"$staging_dir/revision.txt"
(
  cd "$staging_dir"
  sha256sum database.dump private-media.tar.gz env-inventory.example revision.txt >SHA256SUMS
)
tar -C "$staging_dir" -czf - . | age -r "$PROJECT_LEDGER_BACKUP_AGE_RECIPIENT" -o "$final_archive"
sha256sum "$final_archive" >"$final_archive.sha256"
chmod 600 "$final_archive" "$final_archive.sha256"
echo "Encrypted backup created: $final_archive"


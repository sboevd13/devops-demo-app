#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_DIR"

set -a
source .env
set +a

DATE="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_DIR="$PROJECT_DIR/backups/$DATE"

mkdir -p "$BACKUP_DIR"

echo "[1/4] Creating PostgreSQL dump..."

docker compose exec -T db \
    pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    | gzip > "$BACKUP_DIR/database.sql.gz"


echo "[2/4] Saving configuration..."

cp compose.yaml "$BACKUP_DIR/"
cp nginx/nginx.conf "$BACKUP_DIR/"


echo "[3/4] Creating checksums..."

cd "$BACKUP_DIR"

sha256sum \
    database.sql.gz \
    compose.yaml \
    nginx.conf \
    > SHA256SUMS


echo "[4/4] Verifying checksums..."

sha256sum -c SHA256SUMS

echo
echo "Backup completed:"
echo "$BACKUP_DIR"

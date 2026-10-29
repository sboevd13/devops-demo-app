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

echo "[1/5] Stopping application writes..."

docker compose stop nginx app

cleanup() {
    echo "Starting application..."
    docker compose start app nginx >/dev/null
}

trap cleanup EXIT


echo "[2/5] Creating PostgreSQL dump..."

docker compose exec -T db \
    pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    | gzip > "$BACKUP_DIR/database.sql.gz"


echo "[3/5] Saving configuration..."

cp compose.yaml "$BACKUP_DIR/"
cp nginx/nginx.conf "$BACKUP_DIR/"


echo "[4/5] Creating checksums..."

cd "$BACKUP_DIR"

sha256sum \
    database.sql.gz \
    compose.yaml \
    nginx.conf \
    > SHA256SUMS


echo "[5/5] Verifying checksums..."

sha256sum -c SHA256SUMS

echo
echo "Backup completed:"
echo "$BACKUP_DIR"

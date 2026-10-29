#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_HOST="${SOURCE_HOST:-dmitriy@192.168.175.130}"
TARGET_HOST="${TARGET_HOST:-dmitriy@192.168.175.133}"
STACK_DIR="${STACK_DIR:-/opt/devops-demo-app}"

STAMP="$(date +%Y%m%d-%H%M%S)"
MARKER="dr-test-${STAMP}"

LOCAL_TMP="$(mktemp -d)"

TARGET_DUMP="/tmp/source-${STAMP}.sql.gz"
TARGET_SAFETY_BACKUP="${STACK_DIR}/backups/dr-safety-${STAMP}.sql.gz"

TARGET_MUTATED=0
TEST_PASSED=0


restore_target_from_dump() {
    local dump_path="$1"

    ssh "$TARGET_HOST" "
set -Eeuo pipefail

cd '$STACK_DIR'

set -a
source .env
set +a

echo 'Stopping target application...'

docker compose stop app nginx


echo 'Dropping target database...'

docker compose exec -T db \
  psql \
  -v ON_ERROR_STOP=1 \
  -U \"\$POSTGRES_USER\" \
  -d postgres \
  -c \"DROP DATABASE IF EXISTS \\\"\$POSTGRES_DB\\\" WITH (FORCE);\"


echo 'Creating clean target database...'

docker compose exec -T db \
  psql \
  -v ON_ERROR_STOP=1 \
  -U \"\$POSTGRES_USER\" \
  -d postgres \
  -c \"CREATE DATABASE \\\"\$POSTGRES_DB\\\" OWNER \\\"\$POSTGRES_USER\\\";\"


echo 'Importing dump...'

gzip -dc '$dump_path' \
  | docker compose exec -T db \
      psql \
      -v ON_ERROR_STOP=1 \
      -U \"\$POSTGRES_USER\" \
      -d \"\$POSTGRES_DB\"


echo 'Starting target application...'

docker compose up -d app nginx
"
}


wait_for_target() {
    ssh "$TARGET_HOST" "
set -Eeuo pipefail

cd '$STACK_DIR'

for i in \$(seq 1 30)
do
    if curl \
        -kfsS \
        https://127.0.0.1/health \
        >/dev/null 2>&1
    then
        echo 'Application is healthy.'
        exit 0
    fi

    sleep 2
done

echo 'ERROR: application did not become healthy.' >&2

docker compose ps >&2

docker compose logs \
  --tail=100 \
  app nginx \
  >&2

exit 1
"
}


cleanup() {
    local exit_code=$?

    set +e

    echo
    echo "[cleanup] Removing test marker from source..."

    ssh "$SOURCE_HOST" "
cd '$STACK_DIR' &&
set -a &&
source .env &&
set +a &&
docker compose exec -T db \
  psql \
  -U \"\$POSTGRES_USER\" \
  -d \"\$POSTGRES_DB\" \
  -c \"DELETE FROM users WHERE name = '$MARKER';\"
" >/dev/null 2>&1


    if [[ "$TEST_PASSED" -eq 1 ]]
    then
        echo "[cleanup] Removing test marker from target..."

        ssh "$TARGET_HOST" "
cd '$STACK_DIR' &&
set -a &&
source .env &&
set +a &&
docker compose exec -T db \
  psql \
  -U \"\$POSTGRES_USER\" \
  -d \"\$POSTGRES_DB\" \
  -c \"DELETE FROM users WHERE name = '$MARKER';\"
" >/dev/null 2>&1

    elif [[ "$TARGET_MUTATED" -eq 1 ]]
    then
        echo "[cleanup] Test failed after target DB was changed."
        echo "[cleanup] Restoring target safety backup..."

        restore_target_from_dump \
          "$TARGET_SAFETY_BACKUP" \
          >/dev/null 2>&1

        wait_for_target \
          >/dev/null 2>&1

        echo "[cleanup] Target database rolled back."
    fi


    echo "[cleanup] Removing temporary dump from target..."

    ssh "$TARGET_HOST" \
      "rm -f '$TARGET_DUMP'" \
      >/dev/null 2>&1


    rm -rf "$LOCAL_TMP"

    exit "$exit_code"
}


trap cleanup EXIT


echo "========================================"
echo "DISASTER RECOVERY TEST"
echo "========================================"

echo "Source: $SOURCE_HOST"
echo "Target: $TARGET_HOST"
echo "Marker: $MARKER"

echo


echo "[1/9] Checking SSH access..."

ssh -o BatchMode=yes "$SOURCE_HOST" true
ssh -o BatchMode=yes "$TARGET_HOST" true


echo
echo "[2/9] Checking Docker stacks..."

ssh "$SOURCE_HOST" \
  "cd '$STACK_DIR' && docker compose ps"

echo

ssh "$TARGET_HOST" \
  "cd '$STACK_DIR' && docker compose ps"


echo
echo "[3/9] Creating unique test user on source..."

ssh "$SOURCE_HOST" "
cd '$STACK_DIR' &&
set -a &&
source .env &&
set +a &&
docker compose exec -T db \
  psql \
  -v ON_ERROR_STOP=1 \
  -U \"\$POSTGRES_USER\" \
  -d \"\$POSTGRES_DB\" \
  -c \"INSERT INTO users (name) VALUES ('$MARKER');\"
"


echo
echo "[4/9] Running real backup.sh on source..."

BACKUP_PATH="$(
    ssh "$SOURCE_HOST" "
cd '$STACK_DIR' &&
./scripts/backup.sh >/tmp/dr-source-backup.log &&
tail -n 1 /tmp/dr-source-backup.log
"
)"

echo "Source backup:"
echo "$BACKUP_PATH"

ssh "$SOURCE_HOST" \
  "test -s '$BACKUP_PATH/database.sql.gz'"


echo
echo "[5/9] Creating safety backup of target database..."

ssh "$TARGET_HOST" "
cd '$STACK_DIR' &&
mkdir -p backups &&
set -a &&
source .env &&
set +a &&
docker compose exec -T db \
  pg_dump \
  -U \"\$POSTGRES_USER\" \
  -d \"\$POSTGRES_DB\" \
  | gzip > '$TARGET_SAFETY_BACKUP'
"

echo "Target safety backup:"
echo "$TARGET_SAFETY_BACKUP"

ssh "$TARGET_HOST" \
  "test -s '$TARGET_SAFETY_BACKUP'"


echo
echo "[6/9] Copying source database dump..."

scp \
  "$SOURCE_HOST:$BACKUP_PATH/database.sql.gz" \
  "$LOCAL_TMP/database.sql.gz"

scp \
  "$LOCAL_TMP/database.sql.gz" \
  "$TARGET_HOST:$TARGET_DUMP"


echo
echo "[7/9] Restoring database on target..."

TARGET_MUTATED=1

restore_target_from_dump "$TARGET_DUMP"


echo
echo "[8/9] Waiting for target application..."

wait_for_target


echo
echo "[9/9] Verifying restored data..."

FOUND="$(
    ssh "$TARGET_HOST" "
cd '$STACK_DIR' &&
set -a &&
source .env &&
set +a &&
docker compose exec -T db \
  psql \
  -At \
  -U \"\$POSTGRES_USER\" \
  -d \"\$POSTGRES_DB\" \
  -c \"SELECT COUNT(*) FROM users WHERE name = '$MARKER';\"
"
)"


if [[ "$FOUND" != "1" ]]
then
    echo "ERROR: restore verification failed."
    echo "Marker count on target: $FOUND"
    exit 1
fi


TEST_PASSED=1

echo "========================================"
echo "БРАТ оно работает!!! Если ты видишь это сообщение, значит бэкап базы и зпервой vm полностью восстановился на второй vm!"
echo "========================================"

echo "Source backup:"
echo "$BACKUP_PATH"

echo
echo "Target safety backup:"
echo "$TARGET_SAFETY_BACKUP"

echo
echo "Database from app-1 was restored and verified on app-2."

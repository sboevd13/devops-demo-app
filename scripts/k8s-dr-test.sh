#!/usr/bin/env bash
set -Eeuo pipefail

# Tests a real backup created by the CronJob and restores it into a disposable
# database. The production appdb is never replaced by this test.
NAMESPACE=devops-demo
BACKUP_HOST=${BACKUP_HOST:-dmitriy@192.168.175.130}
STAMP=$(date +%Y%m%d%H%M%S)
JOB=dr-backup-${STAMP}
DR_DB=dr_verify_${STAMP}
MARKER=dr-test-${STAMP}

cleanup() {
  kubectl -n "$NAMESPACE" exec postgres-0 -- dropdb -U app --if-exists "$DR_DB" >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" exec postgres-0 -- psql -U app -d appdb -q -c \
    "DELETE FROM users WHERE name = '$MARKER'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" exec postgres-0 -- psql -U app -d appdb -v ON_ERROR_STOP=1 -q -c \
  "INSERT INTO users (name) VALUES ('$MARKER')"

kubectl -n "$NAMESPACE" create job "$JOB" --from=cronjob/postgres-backup
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$JOB" --timeout=240s

BACKUP_PATH=$(kubectl -n "$NAMESPACE" logs "job/$JOB" | sed -n 's/^Backup saved: //p' | tail -n 1)
[[ $BACKUP_PATH == /backups/*.sql.gz ]] || { echo "Backup path not found in Job logs" >&2; exit 1; }
BACKUP_FILE=${BACKUP_PATH##*/}
BACKUP_STEM=${BACKUP_FILE%.sql.gz}
BACKUP_DIR=/opt/devops-demo-app/k8s-backups

ssh "$BACKUP_HOST" "cd '$BACKUP_DIR' && sha256sum -c '$BACKUP_STEM.sha256'"
kubectl -n "$NAMESPACE" exec postgres-0 -- createdb -U app "$DR_DB"

ssh "$BACKUP_HOST" "gzip -dc '$BACKUP_DIR/$BACKUP_FILE'" |
  kubectl -n "$NAMESPACE" exec -i postgres-0 -- \
    psql -U app -d "$DR_DB" -v ON_ERROR_STOP=1 -q

COUNT=$(kubectl -n "$NAMESPACE" exec postgres-0 -- \
  psql -U app -d "$DR_DB" -At -c \
  "SELECT count(*) FROM users WHERE name = '$MARKER'")
[[ $COUNT == 1 ]] || { echo "Restore verification failed: marker count=$COUNT" >&2; exit 1; }

echo "DR TEST PASSED: backup on app-1 restored and verified on app-2 in $DR_DB"

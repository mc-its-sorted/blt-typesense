#!/bin/bash
set -euo pipefail

DATA_DIR="${TYPESENSE_DATA_DIR:-/data}"
BACKUP_URI="${TYPESENSE_BACKUP_URI:-gs://blt-typesense-data}"
SYNC_INTERVAL="${TYPESENSE_BACKUP_INTERVAL_SECONDS:-300}"
API_PORT="${TYPESENSE_API_PORT:-8108}"

mkdir -p "${DATA_DIR}"

echo "Restoring Typesense data from ${BACKUP_URI}/ -> ${DATA_DIR}/..."
if gcloud storage ls "${BACKUP_URI}/" >/dev/null 2>&1; then
  gcloud storage rsync -r "${BACKUP_URI}/" "${DATA_DIR}/" || {
    echo "WARNING: restore from GCS failed; starting with whatever is local"
  }
else
  echo "No existing backup at ${BACKUP_URI}/ (or bucket not readable); starting empty"
fi

# Cloud Run gives each instance a new IP. Restored raft meta points at the old
# peer address, which leaves a single-node cluster stuck in ERROR with
# /health -> {"ok":false}. Raft state is rebuildable; documents live in db/meta.
echo "Clearing raft state for single-node Cloud Run recovery..."
rm -rf "${DATA_DIR}/state"
# Drop FUSE/rsync temp leftovers that can break RocksDB open
find "${DATA_DIR}" -name '*.gstmp' -delete 2>/dev/null || true
find "${DATA_DIR}" -name '*_.gstmp' -delete 2>/dev/null || true

backup_loop() {
  while kill -0 "${TS_PID}" 2>/dev/null; do
    sleep "${SYNC_INTERVAL}"
    if ! kill -0 "${TS_PID}" 2>/dev/null; then
      break
    fi
    if curl -sf "http://127.0.0.1:${API_PORT}/health" | grep -q '"ok":true'; then
      echo "Backup: ${DATA_DIR}/ -> ${BACKUP_URI}/..."
      gcloud storage rsync -r -d "${DATA_DIR}/" "${BACKUP_URI}/" || {
        echo "WARNING: backup to GCS failed"
      }
    else
      echo "Skipping backup: Typesense not healthy"
    fi
  done
}

echo "Starting Typesense on port ${API_PORT}..."
/opt/typesense-server \
  --data-dir="${DATA_DIR}" \
  --api-address=0.0.0.0 \
  --api-port="${API_PORT}" \
  --api-key="${TYPESENSE_API_KEY}" \
  --enable-cors=true \
  --cors-domains="${TYPESENSE_CORS_DOMAINS}" \
  --reset-peers-on-error=true &
TS_PID=$!

cleanup() {
  echo "Shutting down Typesense (pid ${TS_PID})..."
  kill -TERM "${TS_PID}" 2>/dev/null || true
  wait "${TS_PID}" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

backup_loop &
wait "${TS_PID}"
exit $?

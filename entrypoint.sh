#!/bin/bash
set -euo pipefail

DATA_DIR="${TYPESENSE_DATA_DIR:-/data}"
BACKUP_URI="${TYPESENSE_BACKUP_URI:-gs://blt-typesense-data}"
SYNC_INTERVAL="${TYPESENSE_BACKUP_INTERVAL_SECONDS:-300}"
API_PORT="${TYPESENSE_API_PORT:-8108}"

mkdir -p "${DATA_DIR}"

echo "Restoring Typesense snapshot from ${BACKUP_URI}/typesense-backup.tar.gz -> ${DATA_DIR}/..."
if gcloud storage ls "${BACKUP_URI}/typesense-backup.tar.gz" >/dev/null 2>&1; then
  rm -rf /tmp/typesense-backup.tar.gz
  gcloud storage cp "${BACKUP_URI}/typesense-backup.tar.gz" /tmp/typesense-backup.tar.gz || true
  if [[ -f /tmp/typesense-backup.tar.gz ]]; then
    tar -xzf /tmp/typesense-backup.tar.gz -C "${DATA_DIR}/" || {
      echo "WARNING: Failed to extract snapshot tarball"
    }
    rm /tmp/typesense-backup.tar.gz
  fi
else
  echo "No existing snapshot at ${BACKUP_URI}/typesense-backup.tar.gz; starting empty"
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
      echo "Taking Typesense snapshot and backing up to ${BACKUP_URI}/typesense-backup.tar.gz..."
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
      
      # Trigger snapshot
      if curl -sf -X POST "http://127.0.0.1:${API_PORT}/operations/snapshot?snapshot_path=/tmp/ts-snapshot" \
        -H "X-TYPESENSE-API-KEY: ${TYPESENSE_API_KEY}" > /dev/null; then
        
        # Compress and upload
        if tar -czf /tmp/typesense-backup.tar.gz -C /tmp/ts-snapshot .; then
          gcloud storage cp /tmp/typesense-backup.tar.gz "${BACKUP_URI}/typesense-backup.tar.gz" || {
            echo "WARNING: backup to GCS failed"
          }
        else
          echo "WARNING: Failed to compress snapshot"
        fi
      else
        echo "WARNING: Failed to trigger Typesense snapshot"
      fi
      
      # Cleanup
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
    else
      echo "Skipping backup: Typesense not healthy"
    fi
  done
}

wait_for_healthy() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${API_PORT}/health" | grep -q '"ok":true'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_search_api_key() {
  if [[ -z "${TYPESENSE_SEARCH_API_KEY:-}" ]]; then
    echo "TYPESENSE_SEARCH_API_KEY not set; skipping public search key bootstrap"
    return 0
  fi
  if [[ -z "${TYPESENSE_API_KEY:-}" ]]; then
    echo "WARNING: TYPESENSE_API_KEY missing; cannot bootstrap search key"
    return 0
  fi

  echo "Waiting for Typesense health before search key bootstrap..."
  if ! wait_for_healthy; then
    echo "WARNING: Typesense not healthy within 60s; skipping search key bootstrap"
    return 0
  fi

  local body http_code
  body="$(
    TYPESENSE_SEARCH_API_KEY="${TYPESENSE_SEARCH_API_KEY}" python3 - <<'PY'
import json, os
print(json.dumps({
    "description": "public search key",
    "actions": [
        "documents:search",
        "documents:get",
        "collections:get",
        "collections:list",
        "aliases:get",
        "aliases:list",
    ],
    "collections": ["*"],
    "value": os.environ["TYPESENSE_SEARCH_API_KEY"],
}))
PY
  )"

  http_code="$(
    curl -sS -o /tmp/ts-search-key-resp.json -w '%{http_code}' \
      -X POST "http://127.0.0.1:${API_PORT}/keys" \
      -H "X-TYPESENSE-API-KEY: ${TYPESENSE_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${body}" || true
  )"

  case "${http_code}" in
    200|201)
      echo "Public search API key ensured (HTTP ${http_code})"
      ;;
    409)
      echo "Public search API key already present (HTTP 409)"
      ;;
    *)
      echo "WARNING: search key bootstrap failed (HTTP ${http_code:-none}): $(cat /tmp/ts-search-key-resp.json 2>/dev/null || true)"
      # Fixed value may already exist under another description; treat as OK if key works
      if curl -sf "http://127.0.0.1:${API_PORT}/collections" \
        -H "X-TYPESENSE-API-KEY: ${TYPESENSE_SEARCH_API_KEY}" >/dev/null 2>&1; then
        echo "Public search API key already usable"
      fi
      ;;
  esac
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

ensure_search_api_key &
backup_loop &
wait "${TS_PID}"
exit $?

#!/bin/bash
set -euo pipefail

DATA_DIR="${TYPESENSE_DATA_DIR:-/data}"
BACKUP_URI="${TYPESENSE_BACKUP_URI:-gs://blt-typesense-data}"
BACKUP_OBJECT="${BACKUP_URI%/}/typesense-backup.tar.gz"
SYNC_INTERVAL="${TYPESENSE_BACKUP_INTERVAL_SECONDS:-300}"
API_PORT="${TYPESENSE_API_PORT:-8108}"
# Refuse to treat tiny/corrupt archives as valid restores or uploads.
MIN_BACKUP_BYTES="${TYPESENSE_MIN_BACKUP_BYTES:-1024}"

mkdir -p "${DATA_DIR}"

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

backup_has_db() {
  local archive="$1"
  # Use grep without -q and redirect to /dev/null to consume all tar output
  # and prevent SIGPIPE (exit code 141) from breaking 'set -o pipefail'.
  tar -tzf "${archive}" 2>/dev/null | grep -E '(^|/)db(/|$)|(^|/)state(/|$)' >/dev/null
}

restore_from_gcs() {
  log "Restoring Typesense snapshot from ${BACKUP_OBJECT} -> ${DATA_DIR}/..."

  if ! gcloud storage ls "${BACKUP_OBJECT}" >/dev/null 2>&1; then
    log "No existing snapshot at ${BACKUP_OBJECT}; starting empty"
    return 0
  fi

  local tmp_tar="/tmp/typesense-backup.tar.gz"
  rm -f "${tmp_tar}"

  log "Downloading ${BACKUP_OBJECT}..."
  gcloud storage cp "${BACKUP_OBJECT}" "file://${tmp_tar}" \
    || die "failed to download ${BACKUP_OBJECT}"

  [[ -f "${tmp_tar}" ]] || die "download reported success but ${tmp_tar} missing"

  local size
  size="$(stat -c%s "${tmp_tar}" 2>/dev/null || echo 0)"
  log "Downloaded snapshot: ${size} bytes"
  (( size >= MIN_BACKUP_BYTES )) \
    || die "snapshot too small (${size} bytes; min ${MIN_BACKUP_BYTES}) — refusing empty start"

  backup_has_db "${tmp_tar}" \
    || die "snapshot tarball has no db/ entries — refusing empty start"

  log "Snapshot contents (top-level):"
  tar -tzf "${tmp_tar}" | awk -F/ 'NF<=2 {print}' | head -n 40 || true

  # Official restore: wipe data dir, then extract snapshot as the new data-dir.
  find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  tar -xzf "${tmp_tar}" -C "${DATA_DIR}/" \
    || die "failed to extract snapshot tarball into ${DATA_DIR}"
  rm -f "${tmp_tar}"

  # If archive nested one directory, flatten so db/meta sit at DATA_DIR root.
  if [[ ! -d "${DATA_DIR}/db" ]] && [[ ! -d "${DATA_DIR}/state" ]]; then
    local nested
    nested="$(find "${DATA_DIR}" -mindepth 2 -maxdepth 2 -type d \( -name db -o -name state \) 2>/dev/null | head -n 1 || true)"
    if [[ -n "${nested}" ]]; then
      local parent
      parent="$(dirname "${nested}")"
      log "Flattening nested snapshot layout from ${parent}..."
      shopt -s dotglob nullglob
      mv "${parent}"/* "${DATA_DIR}/"
      shopt -u dotglob nullglob
      rm -rf "${parent}"
    fi
  fi

  [[ -d "${DATA_DIR}/db" ]] || [[ -d "${DATA_DIR}/state" ]] \
    || die "after extract, neither db/ nor state/ is present — restore did not produce a usable data dir"

  log "Restore OK. data-dir layout:"
  ls -la "${DATA_DIR}" || true
  du -sh "${DATA_DIR}"/* 2>/dev/null || true
}

restore_from_gcs

# Cloud Run gives each instance a new IP. Restored raft meta points at the old
# peer address, which leaves a single-node cluster stuck in ERROR with
# /health -> {"ok":false}. Raft state is rebuildable; documents live in db/meta.
log "Clearing raft state for single-node Cloud Run recovery..."
rm -rf "${DATA_DIR}/state"
# Drop FUSE/rsync temp leftovers that can break RocksDB open
find "${DATA_DIR}" -name '*.gstmp' -delete 2>/dev/null || true
find "${DATA_DIR}" -name '*_.gstmp' -delete 2>/dev/null || true

collection_count() {
  local body
  body="$(curl -sf "http://127.0.0.1:${API_PORT}/collections" \
    -H "X-TYPESENSE-API-KEY: ${TYPESENSE_API_KEY}" 2>/dev/null || true)"
  if [[ -z "${body}" ]]; then
    echo 0
    return
  fi
  TYPESENSE_COLLECTIONS_JSON="${body}" python3 - <<'PY'
import json, os
try:
    data = json.loads(os.environ["TYPESENSE_COLLECTIONS_JSON"])
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
PY
}

backup_loop() {
  while kill -0 "${TS_PID}" 2>/dev/null; do
    sleep "${SYNC_INTERVAL}"
    if ! kill -0 "${TS_PID}" 2>/dev/null; then
      break
    fi
    if ! curl -sf "http://127.0.0.1:${API_PORT}/health" | grep '"ok":true' >/dev/null; then
      log "Skipping backup: Typesense not healthy"
      continue
    fi

    local colls
    colls="$(collection_count)"
    if (( colls < 1 )); then
      log "Skipping backup: 0 collections (refusing to overwrite GCS with empty index)"
      continue
    fi

    log "Taking Typesense snapshot and backing up to ${BACKUP_OBJECT} (${colls} collections)..."
    rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz

    if ! curl -sf -X POST \
      "http://127.0.0.1:${API_PORT}/operations/snapshot?snapshot_path=/tmp/ts-snapshot" \
      -H "X-TYPESENSE-API-KEY: ${TYPESENSE_API_KEY}" > /dev/null; then
      log "WARNING: Failed to trigger Typesense snapshot"
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
      continue
    fi

    if [[ ! -d /tmp/ts-snapshot/db ]] && [[ ! -d /tmp/ts-snapshot/state ]]; then
      log "WARNING: snapshot missing /tmp/ts-snapshot/db and state; refusing upload"
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
      continue
    fi

    if ! tar -czf /tmp/typesense-backup.tar.gz -C /tmp/ts-snapshot .; then
      log "WARNING: Failed to compress snapshot"
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
      continue
    fi

    local size
    size="$(stat -c%s /tmp/typesense-backup.tar.gz 2>/dev/null || echo 0)"
    if (( size < MIN_BACKUP_BYTES )) || ! backup_has_db /tmp/typesense-backup.tar.gz; then
      log "WARNING: local snapshot invalid (size=${size}); refusing upload"
      rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
      continue
    fi

    if gcloud storage cp /tmp/typesense-backup.tar.gz "${BACKUP_OBJECT}"; then
      log "Backup uploaded (${size} bytes) -> ${BACKUP_OBJECT}"
    else
      log "WARNING: backup to GCS failed"
    fi

    rm -rf /tmp/ts-snapshot /tmp/typesense-backup.tar.gz
  done
}

wait_for_healthy() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if curl -sf "http://127.0.0.1:${API_PORT}/health" | grep '"ok":true' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_search_api_key() {
  if [[ -z "${TYPESENSE_SEARCH_API_KEY:-}" ]]; then
    log "TYPESENSE_SEARCH_API_KEY not set; skipping public search key bootstrap"
    return 0
  fi
  if [[ -z "${TYPESENSE_API_KEY:-}" ]]; then
    log "WARNING: TYPESENSE_API_KEY missing; cannot bootstrap search key"
    return 0
  fi

  log "Waiting for Typesense health before search key bootstrap..."
  if ! wait_for_healthy; then
    log "WARNING: Typesense not healthy within 60s; skipping search key bootstrap"
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
      log "Public search API key ensured (HTTP ${http_code})"
      ;;
    409)
      log "Public search API key already present (HTTP 409)"
      ;;
    *)
      log "WARNING: search key bootstrap failed (HTTP ${http_code:-none}): $(cat /tmp/ts-search-key-resp.json 2>/dev/null || true)"
      if curl -sf "http://127.0.0.1:${API_PORT}/collections" \
        -H "X-TYPESENSE-API-KEY: ${TYPESENSE_SEARCH_API_KEY}" >/dev/null 2>&1; then
        log "Public search API key already usable"
      fi
      ;;
  esac
}

log "Starting Typesense on port ${API_PORT}..."
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
  log "Shutting down Typesense (pid ${TS_PID})..."
  kill -TERM "${TS_PID}" 2>/dev/null || true
  wait "${TS_PID}" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

ensure_search_api_key &
backup_loop &
wait "${TS_PID}"
exit $?

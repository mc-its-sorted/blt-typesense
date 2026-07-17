# blt-typesense

Single-node Typesense on Cloud Run for a small product search index.

## Architecture

| Piece | Choice | Why |
| --- | --- | --- |
| Runtime | Cloud Run gen2, `min-instances=1`, `max-instances=1` | Always one process; never multi-node Raft |
| CPU | `--no-cpu-throttling` | Raft heartbeats need CPU between requests |
| Data dir | Local container disk `/data` | RocksDB + Raft need POSIX local FS |
| Persistence | GCS bucket `gs://blt-typesense-data` via rsync | Backup/restore only — **not** a live mount |
| Public URL | `https://ts.bltdirect.com` via existing HTTPS LB | Ingress restricted to LB |

**Do not mount the GCS bucket with Cloud Storage FUSE at `/data`.** FUSE is not a real filesystem (no proper locking/mmap). Typesense will eventually enter Raft `ERROR` and `/health` returns `{"ok":false}`.

## Deploy

```bash
gcloud builds submit --config=deploy/cloudbuild.yaml --project=blt-prod
```

### One-time: remove GCS FUSE volume (if still present)

`gcloud run deploy` keeps existing volume mounts across updates. If `/data` is still
backed by Cloud Storage FUSE, remove it once:

```bash
gcloud run services update blt-typesense \
  --region=europe-west2 \
  --project=blt-prod \
  --remove-volume=typesense-vol
```

Confirm it is gone:

```bash
gcloud run services describe blt-typesense --region=europe-west2 --project=blt-prod \
  --format='yaml(spec.template.spec.volumes,spec.template.spec.containers[0].volumeMounts)'
# expect: null / empty
```

## Health

```bash
curl -sS https://ts.bltdirect.com/health
# expect: {"ok":true}
```

## Recovery if `/health` is false

Symptoms in logs:

```text
Node with no leader. Resetting peers of size: 1
node ... is in state ERROR, can't reset_peer
```

Cause is almost always stale Raft meta after a restart (new Cloud Run IP) or corrupted state from FUSE.

1. Redeploy this image (entrypoint clears `state/` on every boot and restores `db/` + `meta/` from GCS).
2. If still unhealthy, wipe the bad raft/state objects in the backup bucket, then redeploy:

```bash
gcloud storage rm -r gs://blt-typesense-data/state/**
# optional nuclear option if collections are empty/corrupt:
# gcloud storage rm -r gs://blt-typesense-data/**
gcloud builds submit --config=deploy/cloudbuild.yaml --project=blt-prod
```

3. Re-index from the app/source of truth if the document store was wiped.

## Env / secrets

| Name | Source |
| --- | --- |
| `TYPESENSE_API_KEY` | Secret Manager `blt-typesense-api-key` (admin bootstrap; do not expose to browsers) |
| `TYPESENSE_SEARCH_API_KEY` | Secret Manager `blt-typesense-search-api-key` (public search key; safe for frontend) |
| `TYPESENSE_CORS_DOMAINS` | Cloud Run env |
| `TYPESENSE_BACKUP_URI` | default `gs://blt-typesense-data` |

### Public search API key

Typesense only accepts the **admin** key via `--api-key` / `TYPESENSE_API_KEY`. The public search key is created via `POST /keys` with a fixed `value` so clients do not need a new key after redeploy or data wipe.

On container start, `entrypoint.sh` waits for `/health` and ensures this key exists with:

- **actions:** `documents:search`, `documents:get`, `collections:get`, `collections:list`, `aliases:get`, `aliases:list`
- **collections:** `*`
- **value:** contents of `TYPESENSE_SEARCH_API_KEY`

#### One-time: create the Secret Manager secret

```bash
# Use an existing frontend key, or generate a new long random value:
printf '%s' "$(openssl rand -hex 32)" | \
  gcloud secrets create blt-typesense-search-api-key \
    --project=blt-prod \
    --data-file=-

# If the secret already exists, add a new version instead:
# printf '%s' 'your-fixed-search-key' | \
#   gcloud secrets versions add blt-typesense-search-api-key --project=blt-prod --data-file=-
```

Grant the Cloud Run runtime service account `roles/secretmanager.secretAccessor` on that secret (same as the admin key).

#### Manual one-shot create (if needed)

Full key material is only returned on create; list endpoints show a prefix only. Keep the value in Secret Manager.

```bash
ADMIN_KEY="$(gcloud secrets versions access latest --secret=blt-typesense-api-key --project=blt-prod)"
export SEARCH_KEY="$(gcloud secrets versions access latest --secret=blt-typesense-search-api-key --project=blt-prod)"

curl -sS -X POST "https://ts.bltdirect.com/keys" \
  -H "X-TYPESENSE-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, os
print(json.dumps({
  'description': 'public search key',
  'actions': [
    'documents:search', 'documents:get',
    'collections:get', 'collections:list',
    'aliases:get', 'aliases:list',
  ],
  'collections': ['*'],
  'value': os.environ['SEARCH_KEY'],
}))
" )"
```

```bash
# Verify search key can list collections
curl -sS "https://ts.bltdirect.com/collections" \
  -H "X-TYPESENSE-API-KEY: ${SEARCH_KEY}"
```

## Local test

```bash
./check_port.sh
```

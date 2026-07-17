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
| `TYPESENSE_API_KEY` | Secret Manager `blt-typesense-api-key` |
| `TYPESENSE_CORS_DOMAINS` | Cloud Run env |
| `TYPESENSE_BACKUP_URI` | default `gs://blt-typesense-data` |

## Local test

```bash
./check_port.sh
```

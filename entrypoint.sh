#!/bin/bash

# 1. Pre-stage: Sync existing data from bucket to local /data
echo "Pre-staging data from gs://blt-typesense-data/ to /data..."
# Using gcloud storage as gsutil is deprecated/slower
gcloud storage rsync -r gs://blt-typesense-data/ /data/

# 2. Start the background sync loop (every 5 minutes)
# We run this in the background (&) so it doesn't block Typesense
(
  while true; do
    sleep 300
    echo "Background sync: /data/ -> gs://blt-typesense-data/..."
    gcloud storage rsync -r -d /data/ gs://blt-typesense-data/
  done
) &

# 3. Start Typesense (using exec so it replaces the script process)
echo "Starting Typesense..."
exec /opt/typesense-server \
  --data-dir=/data \
  --api-key="${TYPESENSE_API_KEY}" \
  --enable-cors=true \
  --cors-domains="${TYPESENSE_CORS_DOMAINS}"

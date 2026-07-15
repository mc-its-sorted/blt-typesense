#!/bin/bash
set -euo pipefail

# Load configuration from .env
set -a
source "$(dirname "$0")/.env"
set +a

# Build and push to GCR
docker build \
  --build-arg TYPESENSE_API_KEY="$TYPESENSE_API_KEY" \
  --build-arg TYPESENSE_CORS_DOMAINS="$TYPESENSE_CORS_DOMAINS" \
  -t "$GCP_IMAGE_URL" .
docker push "$GCP_IMAGE_URL"

# Deploy to Cloud Run
# Note: --port 8108 is required as Typesense listens on 8108 by default
gcloud run deploy "$GCP_SERVICE_NAME" \
  --image "$GCP_IMAGE_URL" \
  --region "$GCP_REGION" \
  --project "$GCP_PROJECT_ID" \
  --port 8108 \
  --allow-unauthenticated \
  --platform managed \
  --set-env-vars "^||^TYPESENSE_API_KEY=$TYPESENSE_API_KEY||TYPESENSE_CORS_DOMAINS=$TYPESENSE_CORS_DOMAINS"

echo "Typesense deployment initiated."

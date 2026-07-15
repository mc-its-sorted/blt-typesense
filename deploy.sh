#!/bin/bash

# Configuration
PROJECT_ID=blt-prod
SERVICE_NAME=blt-typesense
IMAGE_URL=gcr.io/$PROJECT_ID/$SERVICE_NAME

# Build and push to GCR
docker build -t $IMAGE_URL .
docker push $IMAGE_URL

# Deploy to Cloud Run
# Note: --port 8108 is required as Typesense listens on 8108 by default
gcloud run deploy $SERVICE_NAME \
  --image $IMAGE_URL \
  --region europe-west2 \
  --project $PROJECT_ID \
  --port 8108 \
  --allow-unauthenticated \
  --platform managed

echo "Typesense deployment initiated."

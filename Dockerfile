FROM typesense/typesense:30.2

ENV TYPESENSE_DATA_DIR=/data
ENV TYPESENSE_BACKUP_URI=gs://blt-typesense-data
ENV TYPESENSE_BACKUP_INTERVAL_SECONDS=300
ENV TYPESENSE_API_PORT=8108

# curl for health checks; gcloud for backup/restore to GCS
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/* \
  && curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt \
  && ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
  && mkdir -p /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EXPOSE 8108

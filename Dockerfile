FROM typesense/typesense:30.2

# Typesense configuration
ENV TYPESENSE_DATA_DIR=/data

# Expose Typesense port
EXPOSE 8108

# Ensure /data exists or use a writable directory
RUN mkdir -p /data

# The base image already sets ENTRYPOINT ["/opt/typesense-server"].
# Runtime configuration (API key, CORS domains, enable-cors) is supplied via
# Cloud Run env vars / secrets instead of being baked into the image.
CMD []

FROM typesense/typesense:30.2

# Typesense configuration
ENV TYPESENSE_DATA_DIR=/data

ARG TYPESENSE_API_KEY
ARG TYPESENSE_CORS_DOMAINS

ENV TYPESENSE_API_KEY=${TYPESENSE_API_KEY}
ENV TYPESENSE_CORS_DOMAINS=${TYPESENSE_CORS_DOMAINS}

# Expose Typesense port
EXPOSE 8108

# Start Typesense (ensure /data exists or use a writable directory)
RUN mkdir -p /data
CMD ["/opt/typesense-server", "--data-dir=/data", "--api-key=${TYPESENSE_API_KEY}", "--cors-domains=${TYPESENSE_CORS_DOMAINS}"]

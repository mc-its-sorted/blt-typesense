FROM typesense/typesense:30.2

# Typesense configuration
ENV TYPESENSE_DATA_DIR=/data

# Install rsync and Google Cloud SDK
RUN apt-get update && apt-get install -y rsync curl python3 && rm -rf /var/lib/apt/lists/*
RUN curl https://sdk.cloud.google.com | bash
ENV PATH=$PATH:/root/google-cloud-sdk/bin

# Copy migration wrapper script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Use the wrapper as the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Expose Typesense port
EXPOSE 8108

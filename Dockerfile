FROM typesense/typesense:30.2

# Typesense configuration
ENV TYPESENSE_DATA_DIR=/data
ENV TYPESENSE_API_KEY=your_secure_api_key_here

# Enable CORS for specified domains
ENV TYPESENSE_CORS_DOMAINS="https://blt3.bltdirect.com,https://www.bltdirect.com"

# Expose Typesense port
EXPOSE 8108

# Start Typesense
CMD ["--data-dir", "/data", "--api-key", "your_secure_api_key_here", "--cors-domains", "https://blt3.bltdirect.com,https://www.bltdirect.com"]

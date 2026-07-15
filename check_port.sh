#!/bin/bash
# Test if a local container behaves correctly
docker build --build-arg TYPESENSE_API_KEY="testkey" -t typesense-test .
docker run -p 8108:8108 -d --name typesense-test typesense-test
sleep 5
# Check if port 8108 is listening
if docker exec typesense-test netstat -tulpn | grep :8108; then
    echo "SUCCESS: Typesense is listening on 8108"
else
    echo "FAILURE: Typesense is NOT listening on 8108"
    docker logs typesense-test
fi
docker rm -f typesense-test

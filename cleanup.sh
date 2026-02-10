#!/bin/bash

echo "Starting cleanup..."

# Destroy Terraform resources
if [ -f .env.docker ]; then
    docker run --env-file .env.docker --rm -it \
      -v ./flink:/home/flink-project/flink \
      -v ./terraform:/home/flink-project/terraform \
      -v ./build.sh:/home/flink-project/build.sh \
      msf-terraform bash build.sh destroy
fi

# Remove credentials file securely
if [ -f .env.docker ]; then
    rm -f .env.docker
    echo "Removed .env.docker"
fi

# Remove Docker image
docker image rm msf-terraform 2>/dev/null || true
echo "Removed Docker image"

echo "Cleanup complete!"


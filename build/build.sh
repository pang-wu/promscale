#!/bin/bash

set -e

ECR_REPO_NAME="promscale"
DOJO_AWS_ACCOUNT_ID="000267950901"
IMAGE_TAG="0.16.0-samsara1"

build_tag="${DOJO_AWS_ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"

echo "Building Docker Image..."
docker build . -f build/Dockerfile -t "${build_tag}"

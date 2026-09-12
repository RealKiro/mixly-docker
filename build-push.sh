#!/usr/bin/env bash
# 本地构建并推送镜像到 GHCR 与 Docker Hub（linux/amd64）
# 前置：docker login ghcr.io 与 docker login 已完成
set -euo pipefail

GHCR_USER="${GHCR_USER:-YOUR_GH_USERNAME}"
DOCKERHUB_USER="${DOCKERHUB_USER:-YOUR_DOCKERHUB_USERNAME}"
TAG="${1:-latest}"

CONTEXT_DIR="$(cd "$(dirname "$0")" && pwd)/官方解压包/mixly_server"

docker buildx build \
  --platform linux/amd64 \
  --tag "ghcr.io/${GHCR_USER}/mixly-server:${TAG}" \
  --tag "${DOCKERHUB_USER}/mixly-server:${TAG}" \
  --push \
  -f "$(cd "$(dirname "$0")" && pwd)/Dockerfile" \
  "${CONTEXT_DIR}"

echo "已推送: ghcr.io/${GHCR_USER}/mixly-server:${TAG} 和 ${DOCKERHUB_USER}/mixly-server:${TAG}"

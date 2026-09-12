#!/usr/bin/env bash
# 本地构建并推送“运行环境镜像”到 GHCR 与 Docker Hub（linux/amd64）
# 镜像不含官方运行包（约 100MB 级），运行包由使用者挂载提供
# 前置：docker login ghcr.io 与 docker login 已完成
set -euo pipefail

GHCR_USER="${GHCR_USER:-RealKiro}"
DOCKERHUB_USER="${DOCKERHUB_USER:-YOUR_DOCKERHUB_USERNAME}"
TAG="${1:-latest}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

docker buildx build \
  --platform linux/amd64 \
  --tag "ghcr.io/${GHCR_USER}/mixly-server:${TAG}" \
  --tag "${DOCKERHUB_USER}/mixly-server:${TAG}" \
  --push \
  -f "${REPO_DIR}/Dockerfile" \
  "${REPO_DIR}"

echo "已推送: ghcr.io/${GHCR_USER}/mixly-server:${TAG} 和 ${DOCKERHUB_USER}/mixly-server:${TAG}"

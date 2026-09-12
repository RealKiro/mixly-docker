#!/usr/bin/env bash
# 本地构建并推送“运行环境镜像”到 GHCR 与 Docker Hub
# 因 Docker Hub 官方 alpine 无 loong64 变体，按架构分别构建
# （loong64 用社区镜像 ghcr.io/loong64/alpine:3），再合并多架构 manifest
# 前置：docker login ghcr.io 与 docker login 已完成
set -euo pipefail

GHCR_USER="${GHCR_USER:-RealKiro}"
DOCKERHUB_USER="${DOCKERHUB_USER:-YOUR_DOCKERHUB_USERNAME}"   # 设为真实用户名则同时推 Docker Hub
TAG="${1:-latest}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GHCR_IMAGE="ghcr.io/${GHCR_USER}/mixly-server"
DH_IMAGE="${DOCKERHUB_USER}/mixly-server"
PUSH_DH=0
[ "$DOCKERHUB_USER" != "YOUR_DOCKERHUB_USERNAME" ] && PUSH_DH=1

build_arch() { # $1=pair $2=platform $3=base_image
    local args=(--platform "$2" --build-arg "BASE_IMAGE=$3" --push --provenance=false)
    local tags=("${GHCR_IMAGE}:${TAG}-$1")
    [ "$PUSH_DH" = 1 ] && tags+=("${DH_IMAGE}:${TAG}-$1")
    local t
    for t in "${tags[@]}"; do args+=(--tag "$t"); done
    docker buildx build "${args[@]}" -f "${REPO_DIR}/Dockerfile" "${REPO_DIR}"
}

push_manifest() { # $1=镜像名
    docker manifest create "${1}:${TAG}" \
        --amend "${1}:${TAG}-amd64" \
        --amend "${1}:${TAG}-arm64" \
        --amend "${1}:${TAG}-loong64"
    docker manifest push "${1}:${TAG}"
}

build_arch amd64  "linux/amd64"  "alpine:3"
build_arch arm64  "linux/arm64"  "alpine:3"
build_arch loong64 "linux/loong64" "ghcr.io/loong64/alpine:3"

push_manifest "$GHCR_IMAGE"
[ "$PUSH_DH" = 1 ] && push_manifest "$DH_IMAGE"

echo "已推送多架构 manifest: ${GHCR_IMAGE}:${TAG}" \
  && { [ "$PUSH_DH" = 1 ] && echo "以及 ${DH_IMAGE}:${TAG}" || true; }

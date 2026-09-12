# syntax=docker/dockerfile:1
#
# Mixly 离线服务端 运行环境镜像（不含官方运行包，三架构：amd64 + arm64 + loong64）
# 说明：官方 mixio 为 glibc 动态链接 ELF（Node.js/pkg 打包），
#       Alpine(musl) 需借助 gcompat 兼容层运行，并补充 libstdc++/libgcc。
#       官方按机型提供 x64 / arm64 / loong64 运行包（启动文件同名 mixio），
#       使用者按机器架构下载对应压缩包放入映射路径即可，容器不做架构转换，
#       启动时会校验运行包架构与机器是否匹配（见 docker-entrypoint.sh）。
#       基础镜像用 alpine:3 滚动标签：始终指向最新 3.x 稳定版
#       （loongarch64 自 Alpine 3.21 起为官方移植架构，3.x 均覆盖）。
#       注意：Docker Hub 官方 alpine 镜像不含 loong64 变体，loong64 构建需
#       通过 BASE_IMAGE 指定社区移植镜像（如 ghcr.io/loong64/alpine:3），
#       由 CI/脚本按架构分别构建后用 manifest 合并。
#       若某次升级后 gcompat 兼容性异常，可临时固定为具体版本（如 alpine:3.22）。
#
# 首次使用：将官方 mixly_server 压缩包解压后放到映射路径，
#           容器启动时若未检测到运行包会打印放置指引并退出。

ARG BASE_IMAGE=alpine:3

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="mixly-server-runtime" \
      org.opencontainers.image.description="Mixly 4 离线服务端运行环境（官方运行包需挂载提供）" \
      org.opencontainers.image.source="https://mixly.cn"

# gcompat 提供 glibc->musl 兼容层；su-exec 以非 root 运行 mixio；tini 作 PID 1 转发信号
RUN apk add --no-cache gcompat libstdc++ libgcc tzdata tini su-exec \
    && addgroup -S mixly \
    && adduser -S -G mixly -h /opt/mixly_server mixly

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 官方运行包挂载点：需包含 mixio/ mixly/ mixco/ 三个目录
VOLUME /opt/mixly_server

ENV TZ=Asia/Shanghai

# 8080 HTTP | 8443 HTTPS | 18084 管理模式 | 1883 MQTT | 8083/8084 WS(MQTT) | 8082/8086 Yjs
EXPOSE 8080 443 8443 18084 1883 8082 8083 8084 8086

ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint.sh"]

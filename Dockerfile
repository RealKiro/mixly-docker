# syntax=docker/dockerfile:1
#
# Mixly 离线服务端 运行环境镜像（不含官方运行包，多架构：amd64 + arm64）
# 说明：官方 mixio 为 glibc 动态链接 ELF（Node.js/pkg 打包），
#       Alpine(musl) 需借助 gcompat 兼容层运行，并补充 libstdc++/libgcc。
#       x86_64 直接使用运行包自带二进制；ARM64 由入口脚本从官方
#       Gitee 发行仓库下载 arm64 内核（缓存到挂载目录）。
#
# 首次使用：将官方 mixly_server 压缩包（百度网盘下载）解压后放到映射路径，
#           容器启动时若未检测到运行包会打印放置指引并退出。

FROM alpine:3.20

LABEL org.opencontainers.image.title="mixly-server-runtime" \
      org.opencontainers.image.description="Mixly 4 离线服务端运行环境（官方运行包需挂载提供）" \
      org.opencontainers.image.source="https://mixly.cn"

# gcompat 提供 glibc->musl 兼容层；curl 供 arm64 首启下载内核；
# su-exec 以非 root 运行 mixio；tini 作 PID 1 转发信号
RUN apk add --no-cache gcompat libstdc++ libgcc tzdata tini su-exec curl ca-certificates \
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

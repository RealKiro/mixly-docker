# syntax=docker/dockerfile:1
#
# Mixly 离线服务端（mixly_server）Docker 镜像
# 说明：官方 mixio 为 glibc 动态链接的 x86-64 ELF（Node.js/pkg 打包），
#       Alpine(musl) 需借助 gcompat 兼容层运行，并补充 libstdc++/libgcc。
#       仅支持 linux/amd64（官方二进制无 arm64 版本）。

FROM alpine:3.20

ARG TARGETPLATFORM
LABEL org.opencontainers.image.title="mixly-server" \
      org.opencontainers.image.description="Mixly 4 离线服务端 (mixio + mixly + mixco)" \
      org.opencontainers.image.source="https://mixly.cn"

# gcompat 提供 glibc->musl 兼容层；tzdata 供时区设置；tini 作 PID 1 转发信号
RUN apk add --no-cache gcompat libstdc++ libgcc tzdata tini \
    && addgroup -S mixly \
    && adduser -S -G mixly -h /opt/mixly_server mixly

# 复制服务端（构建上下文 = 官方解压包/mixly_server）
COPY --chown=mixly:mixly . /opt/mixly_server

# 运行时可写目录（推荐用 volume 挂载持久化）
RUN mkdir -p /opt/mixly_server/mixio/storage \
             /opt/mixly_server/mixio/store \
             /opt/mixly_server/mixio/logs \
    && chown -R mixly:mixly /opt/mixly_server/mixio

USER mixly
WORKDIR /opt/mixly_server/mixio

ENV TZ=Asia/Shanghai

EXPOSE 8080 443 8443 1883 8082 8083 8084 8086

# mixio 从当前目录读取 config/config.json，并托管 ../mixly 与 ../mixco
# 官方指令：mixio start / stop / help（见 https://gitee.com/mixly2/mixio）
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["./mixio", "start"]

# syntax=docker/dockerfile:1
#
# Mixly 4.0（MixSuite）离线服务端 运行环境镜像
# （不含官方运行包，三架构：amd64 + arm64 + loong64）
#
# 背景：Mixly 4.0 起官方只有一个发行版——内置 MixIO 的 MixSuite，
# 与旧版 mixly_server（Node/pkg 单文件 mixio）的本质区别：
#   * MixlyServer 是 NW.js(Chromium 154 + Node 24) 桌面壳：启动器 exec .host/nw
#     加载 mixio-app，MixIO 服务以【同进程】方式内嵌运行
#     （nw-main.js require mixio.js），前台运行、自行处理 SIGTERM/SIGINT，
#     不再像旧版 mixio 那样自我 daemon 化。
#   * 强制 HTTPS-only：每次启动都会把 mixio-app/config/config.json 的
#     MIXIO_HTTP_PORT 改写为 0，HTTP(8080) 不可用；主入口为
#     https://<ip>:8443（运行包自带自签证书）。
#   * 数据目录从 mixio/ 变为 mixio-app/：SQLite 在 mixio-app/storage/，
#     日志在 mixio-app/logs/，配置/证书在 mixio-app/config/。
#   * NW.js 是 glibc 动态链接的 Debian 系构建，且需要 X11 显示服务器：
#     基础镜像用 debian:trixie-slim，内置 Xvfb 虚拟显示（浏览器访问
#     不依赖显示服务，GUI 壳仅作本地运维兜底）。
#     loong64 用社区同步镜像 ghcr.io/loong64/debian:trixie-slim
#     （Docker Hub 官方 debian 无 loong64 变体）。
#
# 官方按机型提供 MixSuite-linux-x64 / -arm64 / -loong64 三个压缩包
# （启动文件同名 MixlyServer），按机器架构下载解压后放入映射路径；
# 容器不做架构转换，启动时校验 .host/nw 的 ELF 架构与机器是否匹配
# （见 docker-entrypoint.sh）。
#
# 首次使用：解压 MixSuite-linux-<架构>/ 内的【全部内容】到映射路径，
#           容器启动时若未检测到运行包会打印放置指引并退出。

ARG BASE_IMAGE=debian:trixie-slim

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="mixly-server-runtime" \
      org.opencontainers.image.description="Mixly 4.0 MixSuite 离线服务端运行环境（官方运行包需挂载提供）" \
      org.opencontainers.image.source="https://mixly.cn"

# NW.js(Chromium) 运行时依赖（Debian 官方源）：
#   GTK3 / NSS / X11 / ALSA / fontconfig / GBM 等；Xvfb 虚拟显示；
#   gosu 降权；tini 信号转发；curl/ps/net-tools 供健康检查与启动取证。
#   x11-utils 提供 xdpyinfo：NW.js 窗口创建失败时，X 服务器的 visual/扩展
#   是最常见的环境根因，入口脚本的自动取证会调用它（见 docker-entrypoint.sh）。
#   不装中文字体：GUI 壳只在容器内虚拟显示上作运维兜底，页面由客户端渲染。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        xvfb x11-utils \
        libgtk-3-0 libnss3 libnspr4 libasound2 \
        libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
        libcairo2 libcairo-gobject2 libcups2 libdbus-1-3 libexpat1 \
        libfontconfig1 libfreetype6 libgbm1 libdrm2 libatomic1 \
        libpango-1.0-0 libpangocairo-1.0-0 \
        libx11-6 libx11-xcb1 libxau6 libxcb1 libxcomposite1 libxcursor1 \
        libxdamage1 libxdmcp6 libxext6 libxfixes3 libxi6 libxrandr2 \
        libxrender1 libxss1 libxtst6 libxkbcommon0 \
        ca-certificates tzdata tini gosu \
        curl procps net-tools \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r mixly \
    && useradd -r -g mixly -d /opt/mixly_server -s /usr/sbin/nologin mixly \
    # --- 体积瘦身：删除用不到的 Mesa 软件 3D 渲染栈 ---
    # 实测 libnw.so 硬链接 libgbm.so.1，但 libgbm.so.1 的 DT_NEEDED 只有
    # libdrm/libexpat/libm/libc 四个小库，并不链接 mesa-libgallium。
    # 真正拉入 libgallium → libLLVM → libz3（约 190MiB）的是 Xvfb 的 GLX
    # 扩展 libGLX_mesa 与 DRI 驱动；入口脚本以 -extension GLX 启动 Xvfb，
    # NW.js 又传 --disable-gpu 且自带 SwiftShader，这套软件 3D 栈用不上。
    # glob 覆盖 amd64 / arm64 / loong64 三种 multiarch 路径。
    && { _gbm_found=0; \
         for d in /usr/lib/*-linux-gnu /usr/lib/*-linux-gnueabihf; do \
             [ -d "$d" ] || continue; \
             rm -f "$d"/libLLVM*.so* "$d"/libgallium*.so* "$d"/libz3.so* \
                   "$d"/libGLX_mesa.so* "$d"/libEGL_mesa.so* \
                   "$d"/libvulkan_lvp.so*; \
             rm -rf "$d"/dri "$d"/systemd; \
             if ls "$d"/libgbm.so.1* >/dev/null 2>&1; then _gbm_found=1; fi; \
         done; \
         [ "$_gbm_found" -eq 1 ] || { \
             echo "ERROR: libgbm.so.1 缺失，NW.js 将无法加载，终止构建" >&2; exit 1; }; } \
    # adwaita-icon-theme / shared-mime-info 是 libgtk-3 的硬依赖，systemd 由
    # dbus-user-session 拉入；purge 会连带卸 GTK，只删数据文件保持 dpkg 自洽。
    # mime 与 gtk-3.0 schema 保留，避免影响 GTK/GIO 初始化。
    && rm -rf /usr/share/icons/Adwaita /usr/share/doc /usr/share/man \
              /usr/share/info /usr/lib/systemd /usr/bin/systemctl /var/cache/apt

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 官方运行包挂载点：需包含 MixlyServer / .host/ / mixio-app/ / mixly/ 等
VOLUME /opt/mixly_server

ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8

# 8443 HTTPS 主入口（MixSuite 强制 HTTPS，无 HTTP 端口）
# 18084 管理模式 | 1883 MQTT | 8083/8084 WS/WSS | 8082/8086 Yjs 协同
EXPOSE 8443 18084 1883 8083 8084 8082 8086

# 健康检查：直接探测 8443 是否有 MixIO 在服务。
# NW.js 外壳活着 ≠ MixIO 服务已就绪（初始化卡住时容器仍是 running 但网页打不开），
# 这个检查让 `docker ps` 的 STATUS 列如实显示 healthy / unhealthy，不用猜日志。
# 宽限期 180s：首次启动要初始化 SQLite、拉证书（离线时会超时）、起 NW 壳，较慢属正常。
HEALTHCHECK --interval=30s --timeout=8s --start-period=180s --retries=3 \
    CMD curl -ksf -o /dev/null --max-time 6 https://127.0.0.1:8443/ || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]

#!/bin/sh
# Mixly 服务端容器入口：检测官方运行包 -> 修正权限 -> 以非 root 启动
# 官方运行包按机器架构选择（x64 / arm64 / loong64，启动文件同名 mixio），
# 放入映射路径即可；容器只提供运行环境，不做架构转换与下载。
set -e

SERVER_DIR="/opt/mixly_server"
MIXIO_DIR="$SERVER_DIR/mixio"
BIN="$MIXIO_DIR/mixio"

if [ ! -d "$MIXIO_DIR" ] || [ ! -d "$SERVER_DIR/mixly" ] || [ ! -d "$SERVER_DIR/mixco" ] || [ ! -f "$BIN" ]; then
    cat >&2 <<'EOF'
==========================================================================
 [!] 未检测到 Mixly 官方运行包，容器无法启动。

 请按以下步骤放置运行包（首次运行 / 升级包缺失时）：

   1. 按你的机器架构（x64 / arm64 / loong64，不清楚可咨询主机厂家）
      从官方百度网盘下载对应的 mixly_server 压缩包
   2. 解压后得到 mixly_server 文件夹（内含 mixio/ mixly/ mixco/ 三个目录）
   3. 将 mixly_server 文件夹内的【全部内容】放入容器的映射路径，例如：

        群晖:    /docker/mixly/mixly_server/    （对应 compose 中的 ./mixly_server）
        命令行:  docker run 时 -v /你的路径/mixly_server:/opt/mixly_server

      放置后应存在:
        <映射路径>/mixio/mixio   （启动文件）
        <映射路径>/mixio/config  （配置与证书）
        <映射路径>/mixly/        （编辑器静态资源）
        <映射路径>/mixco/        （课程静态资源）
   4. 重新启动容器（docker restart / Container Manager 里重启）

 检测通过后本提示不再出现。
==========================================================================
EOF
    exit 1
fi

# zip 解压后常丢失执行位；官方说明亦要求 chmod +x ./mixio
chmod +x "$BIN" || true

# 可写目录：数据(storage) 项目(store) 日志(logs)，交给容器内 mixly 用户
mkdir -p "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs"
chown -R mixly:mixly "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs" 2>/dev/null || true

cd "$MIXIO_DIR"
# 官方指令：mixio start / stop / help（见 https://gitee.com/mixly2/mixio）
exec su-exec mixly:mixly ./mixio start

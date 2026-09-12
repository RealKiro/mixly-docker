#!/bin/sh
# Mixly 服务端容器入口：
#   检测官方运行包 -> 按主机架构选择 mixio 内核 -> 修正权限 -> 以非 root 启动
# ARM64 设备首次运行会从官方 Gitee 发行仓库下载 arm64 内核并缓存在挂载目录。
set -e

SERVER_DIR="/opt/mixly_server"
MIXIO_DIR="$SERVER_DIR/mixio"
X64_BIN="$MIXIO_DIR/mixio"
ARM_BIN="$MIXIO_DIR/mixio.arm64"
ARM64_URL="https://gitee.com/bnu_mixly/mixio-linux-arm64-dist/raw/master/mixio"

missing_package() {
    cat >&2 <<'EOF'
==========================================================================
 [!] 未检测到 Mixly 官方运行包，容器无法启动。

 请按以下步骤放置运行包（首次运行 / 升级包缺失时）：

   1. 从官方百度网盘下载 mixly_server 压缩包
      （下载地址见项目 README，或向 mixly.cn 官方获取）
   2. 解压后得到 mixly_server 文件夹（内含 mixio/ mixly/ mixco/ 三个目录）
   3. 将 mixly_server 文件夹内的【全部内容】放入容器的映射路径，例如：

        群晖:    /docker/mixly/mixly_server/    （对应 compose 中的 ./mixly_server）
        命令行:  docker run 时 -v /你的路径/mixly_server:/opt/mixly_server

      放置后应存在:
        <映射路径>/mixio/     （服务端：config/ storage/ store/ logs/ mixio）
        <映射路径>/mixly/     （编辑器静态资源）
        <映射路径>/mixco/     （课程静态资源）
   4. 重新启动容器（docker restart / Container Manager 里重启）

 检测通过后本提示不再出现。
==========================================================================
EOF
}

# 包结构检测：三个目录缺一不可（x86_64 还要求自带二进制存在）
if [ ! -d "$MIXIO_DIR" ] || [ ! -d "$SERVER_DIR/mixly" ] || [ ! -d "$SERVER_DIR/mixco" ]; then
    missing_package
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)
        if [ ! -f "$X64_BIN" ]; then
            missing_package
            exit 1
        fi
        # zip 解压后常丢失执行位；官方说明亦要求 chmod +x ./mixio
        chmod +x "$X64_BIN"
        EXEC_BIN="$X64_BIN"
        ;;
    aarch64|arm64)
        if [ ! -f "$ARM_BIN" ]; then
            echo "[INFO] 检测到 ARM64 设备，正在下载官方 arm64 版 mixio 内核（约 143MB，仅首次）..."
            curl -fL --retry 3 -o "$ARM_BIN.tmp" "$ARM64_URL" 2>/dev/null \
                || wget -q -O "$ARM_BIN.tmp" "$ARM64_URL" \
                || {
                    rm -f "$ARM_BIN.tmp"
                    cat >&2 <<'EOF'
==========================================================================
 [!] arm64 内核下载失败（容器可能无外网访问）。

 请手动下载后放到挂载目录，命名为 mixio.arm64：

   https://gitee.com/bnu_mixly/mixio-linux-arm64-dist/raw/master/mixio

 放置后路径应为: <映射路径>/mixio/mixio.arm64
==========================================================================
EOF
                    exit 1
                }
            mv "$ARM_BIN.tmp" "$ARM_BIN"
            echo "[INFO] arm64 内核已缓存到 $ARM_BIN，下次启动不再下载"
        fi
        chmod +x "$ARM_BIN"
        EXEC_BIN="$ARM_BIN"
        ;;
    *)
        echo "[!] 不支持的架构: $ARCH（官方仅提供 x86_64 / arm64 内核）" >&2
        exit 1
        ;;
esac

# 可写目录：数据(storage) 项目(store) 日志(logs)，交给容器内 mixly 用户
mkdir -p "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs"
chown -R mixly:mixly "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs" 2>/dev/null || true

cd "$MIXIO_DIR"
# 官方指令：mixio start / stop / help（见 https://gitee.com/mixly2/mixio）
exec su-exec mixly:mixly "$EXEC_BIN" start

#!/bin/sh
# Mixly 服务端容器入口：检测官方运行包 -> 校验架构匹配 -> 修正权限 -> 以非 root 启动
# 官方运行包按机器架构提供（x64 / arm64 / loong64，启动文件同名 mixio），
# 本脚本会在启动前校验运行包架构与机器是否一致，避免用户下错压缩包。
set -e

SERVER_DIR="/opt/mixly_server"
MIXIO_DIR="$SERVER_DIR/mixio"
BIN="$MIXIO_DIR/mixio"

missing_package() {
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

      放置后应存在（必需）:
        <映射路径>/mixio/mixio   （启动文件）
        <映射路径>/mixio/config  （配置与证书）
        <映射路径>/mixly/        （编辑器静态资源）
      可选（因下载版本而异）:
        <映射路径>/mixco/        （课程静态资源）
        <映射路径>/mixai/        （MixAI 静态资源）
   4. 重新启动容器（docker restart / Container Manager 里重启）

 检测通过后本提示不再出现。
==========================================================================
EOF
}

# 读取 ELF 头 e_machine 字段（偏移 18，2 字节小端），输出架构名
elf_arch() {
    hdr=$(dd if="$1" bs=1 skip=18 count=2 2>/dev/null | od -An -tu1 2>/dev/null | tr -s ' \n' ' ')
    set -- $hdr
    case $(( ${1:-0} + ${2:-0} * 256 )) in
        62)  echo "x64" ;;
        183) echo "arm64" ;;
        258) echo "loong64" ;;
        *)   echo "unknown" ;;
    esac
}

# 包结构检测：mixio/ 与 mixly/ 必需；mixco/、mixai/ 因版本而异，不强制
if [ ! -d "$MIXIO_DIR" ] || [ ! -d "$SERVER_DIR/mixly" ] || [ ! -f "$BIN" ]; then
    missing_package
    exit 1
fi

# 环境校验：运行包架构须与机器架构一致（防止下错压缩包）
case "$(uname -m)" in
    x86_64)      HOST_ARCH="x64" ;;
    aarch64)     HOST_ARCH="arm64" ;;
    loongarch64) HOST_ARCH="loong64" ;;
    *)           HOST_ARCH="" ;;
esac

if [ -n "$HOST_ARCH" ]; then
    BIN_ARCH=$(elf_arch "$BIN")
    if [ "$BIN_ARCH" != "unknown" ] && [ "$BIN_ARCH" != "$HOST_ARCH" ]; then
        cat >&2 <<EOF
==========================================================================
 [!] 运行包与机器架构不匹配，容器无法启动。

     当前机器架构:  $HOST_ARCH
     运行包 mixio 架构: $BIN_ARCH（读取自 $BIN 的 ELF 头）

     请从官方百度网盘下载【$HOST_ARCH】架构的 mixly_server 压缩包，
     解压后替换映射路径中的内容，再重启容器。
==========================================================================
EOF
        exit 1
    fi
    echo "[INFO] 运行包架构校验通过: $BIN_ARCH（机器: $HOST_ARCH）"
fi

# zip 解压后常丢失执行位；官方说明亦要求 chmod +x ./mixio
chmod +x "$BIN" || true

# 可写目录：数据(storage) 项目(store) 日志(logs)，交给容器内 mixly 用户
mkdir -p "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs"
chown -R mixly:mixly "$MIXIO_DIR/storage" "$MIXIO_DIR/store" "$MIXIO_DIR/logs" 2>/dev/null || true

cd "$MIXIO_DIR"
# 官方指令：mixio start / stop / help（见 https://gitee.com/mixly2/mixio）
exec su-exec mixly:mixly ./mixio start

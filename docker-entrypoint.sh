#!/bin/sh
# Mixly 4.0（MixSuite）服务端容器入口：
#   定位官方运行包 -> 校验架构匹配 -> (root) 预建/降权数据目录 -> 起 Xvfb -> exec MixlyServer
#
# MixSuite 包结构（Mixly 4.0 起官方唯一发行版，替代旧版 mixly_server）：
#   <映射目录>/MixlyServer          启动器（ELF；按环境变量写 config 后 exec .host/nw）
#   <映射目录>/.host/nw              NW.js 加载器（ELF；dlopen .host/lib/libnw.so）
#   <映射目录>/mixio-app/            NW 应用：nw-main.js 同进程 require mixio.js = MixIO 服务
#                                     config/ 配置与证书  storage/ SQLite  logs/ 日志  runtime/
#   <映射目录>/mixly/                Mixly 编辑器静态资源（建议保留，缺失仅编辑器不可用）
#   <映射目录>/mixco/ mixmo/         课程 / MixMO 静态资源（可选，因包而异）
#
# 运行方式与旧版 mixio 的区别：MixlyServer 前台运行、不 daemon 化，
# 自行处理 SIGTERM/SIGINT 做优雅退出，因此这里直接 exec，无需守护循环。
set -e

SERVER_DIR="${MIXLY_SERVER_DIR:-/opt/mixly_server}"
BIN_NAME="MixlyServer"

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint][WARN] $*" >&2; }

missing_package() {
    cat >&2 <<'EOF'
==========================================================================
 [!] 未检测到 Mixly 官方运行包（MixSuite），容器无法启动。

 Mixly 4.0 起官方只有一个发行版：内置 MixIO 的 MixSuite。
 请按你的机器架构下载对应压缩包（x64 / arm64 / loong64，不清楚可咨询主机厂家）：

   MixSuite-linux-x64.zip      → Intel/AMD 群晖、PC
   MixSuite-linux-arm64.zip    → ARM 群晖、国产新创电脑
   MixSuite-linux-loong64.zip  → 龙芯电脑

 放置步骤：
   1. 解压得到 MixSuite-linux-<架构>/ 目录
   2. 把该目录【里面的全部内容】放进容器的映射路径，例如：

        群晖:    /docker/mixly/mixly_server/   （对应 compose 中的 ./mixly_server）
        命令行:  docker run 时 -v /你的路径/mixly_server:/opt/mixly_server

      放置后应存在（必需）:
        <映射路径>/MixlyServer        （启动器）
        <映射路径>/.host/nw           （NW.js 运行时加载器）
        <映射路径>/mixio-app/mixio.js （MixIO 服务端）
      建议保留:
        <映射路径>/mixly/             （Mixly 编辑器）
   3. 重新启动容器（docker restart / Container Manager 里重启）

 注意：不要把整个 MixSuite-linux-x64 文件夹再套一层，要放它【里面】的内容。
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

# ---------------------------------------------------------------- 运行包定位
# 常见误操作：解压后把整个 MixSuite-linux-x64 文件夹放进了映射目录（多套一层）。
# 容忍一层嵌套：在 $SERVER_DIR 及其下一级目录中找 MixlyServer。
if [ ! -f "$SERVER_DIR/$BIN_NAME" ]; then
    for _sub in "$SERVER_DIR"/*/; do
        [ -f "$_sub/$BIN_NAME" ] || continue
        warn "在 $_sub 下发现 $BIN_NAME（多嵌套了一层目录）。已自动使用该目录，"
        warn "但建议解压时直接把 MixSuite-linux-<架构>/ 里面的内容放进映射路径。"
        SERVER_DIR="${_sub%/}"
        break
    done
fi

APP_DIR="$SERVER_DIR/mixio-app"
NW_BIN="$SERVER_DIR/.host/nw"

# 包结构检测：启动器 / NW 运行时 / mixio-app 三要素必需；mixly 建议保留
if [ ! -f "$SERVER_DIR/$BIN_NAME" ] || [ ! -f "$NW_BIN" ] \
   || [ ! -f "$APP_DIR/package.json" ] || [ ! -f "$APP_DIR/mixio.js" ]; then
    missing_package
    exit 1
fi
[ -d "$SERVER_DIR/mixly" ] || warn "未发现 mixly/ 目录：MixIO 服务可正常运行，但 Mixly 编辑器将不可用。"

# 环境校验：运行包架构须与机器架构一致（防止下错压缩包）
case "$(uname -m)" in
    x86_64)      HOST_ARCH="x64" ;;
    aarch64)     HOST_ARCH="arm64" ;;
    loongarch64) HOST_ARCH="loong64" ;;
    *)           HOST_ARCH="" ;;
esac

if [ -n "$HOST_ARCH" ]; then
    BIN_ARCH=$(elf_arch "$NW_BIN")
    if [ "$BIN_ARCH" != "unknown" ] && [ "$BIN_ARCH" != "$HOST_ARCH" ]; then
        cat >&2 <<EOF
==========================================================================
 [!] 运行包与机器架构不匹配，容器无法启动。

     当前机器架构:      $HOST_ARCH
     运行包 .host/nw 架构: $BIN_ARCH（读取自 ELF 头）

     请下载【$HOST_ARCH】架构的 MixSuite-linux-$HOST_ARCH.zip，
     解压后替换映射路径中的内容，再重启容器。
==========================================================================
EOF
        exit 1
    fi
    log "运行包架构校验通过: $BIN_ARCH（机器: $HOST_ARCH）"
fi

# ---------------------------------------------------------------- root 准备
# X11 socket 目录（root 与 --user 两种方式都需要；非 root 时 /tmp 可写也能建）
mkdir -p /tmp/.X11-unix 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# 以 root 启动时：预建可写数据目录并交给 mixly 用户、修执行位，
# 然后用 gosu 降权重新执行本脚本（之后 id -u != 0，跳过本段）。
if [ "$(id -u)" = "0" ]; then
    # MixSuite 的可写位置：mixio-app/{storage,logs,config,runtime}（服务数据）、
    # mixio-app 与套件根目录本身（pid.info / user-data / config 重建）。
    # .host、mixly、mixco、mixmo 等静态大目录保持 root 只读，不做递归 chown。
    MIXLY_UID=$(id -u mixly)
    log "root: 开始准备数据目录（套件根=$SERVER_DIR, mixly uid=$MIXLY_UID）"
    for _d in "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" "$APP_DIR/runtime"; do
        mkdir -p "$_d"
        [ "$(stat -c '%u' "$_d" 2>/dev/null)" = "$MIXLY_UID" ] || chown -R mixly:mixly "$_d"
    done
    mkdir -p "$SERVER_DIR/user-data"
    [ "$(stat -c '%u' "$SERVER_DIR/user-data" 2>/dev/null)" = "$MIXLY_UID" ] \
        || chown -R mixly:mixly "$SERVER_DIR/user-data"
    chown mixly:mixly "$SERVER_DIR" "$APP_DIR"

    # 自检：五个可写目录必须都存在。缺任何一个都直接报错退出，
    # 把问题暴露在启动阶段，而不是留到后面出现诡异症状。
    for _d in "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" \
              "$APP_DIR/runtime" "$SERVER_DIR/user-data"; do
        if [ ! -d "$_d" ]; then
            echo "[entrypoint][ERROR] 数据目录创建失败: $_d" >&2
            ls -ld "$SERVER_DIR" "$APP_DIR" >&2 || true
            exit 1
        fi
    done
    log "root: 数据目录就绪: $(ls -d \
        "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" \
        "$APP_DIR/runtime" "$SERVER_DIR/user-data" 2>&1 | tr '\n' ' ')"

    # zip 解压后常丢失执行位；firstrun.sh 亦要求对这三个文件 chmod +x
    chmod +x "$SERVER_DIR/$BIN_NAME" "$NW_BIN" \
        "$SERVER_DIR/.host/chrome_crashpad_handler" 2>/dev/null || true

    # gosu 不改 HOME；Chromium/NW 的 crashpad、fontconfig 等组件需要可写的 HOME
    export HOME="/tmp/mixly-home"
    mkdir -p "$HOME" && chown mixly:mixly "$HOME"

    exec gosu mixly:mixly "$0" "$@"
fi

# 非 root 直接运行（--user）时尽量修执行位，失败不致命
chmod +x "$SERVER_DIR/$BIN_NAME" "$NW_BIN" 2>/dev/null || true

# ---------------------------------------------------------------- Xvfb 虚拟显示
# NW.js 需要 X11 才能建窗口；服务端部署用 Xvfb 兜底。浏览器访问不依赖它。
DISPLAY_NUM="${MIXLY_DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
# 同一容器重启后 PID 命名空间是全新的，上一次的 X socket/lock 已是残留
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp &
XVFB_PID=$!

_waited=0
while [ ! -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; do
    kill -0 "$XVFB_PID" 2>/dev/null || {
        echo "[entrypoint][ERROR] Xvfb 启动失败（虚拟显示不可用）。" >&2
        exit 1
    }
    [ "$_waited" -ge 15 ] && {
        echo "[entrypoint][ERROR] Xvfb 就绪超时（15s）。" >&2
        exit 1
    }
    sleep 1
    _waited=$((_waited + 1))
done
log "Xvfb 虚拟显示已就绪: $DISPLAY"

# ---------------------------------------------------------------- 启动服务
# MixlyServer 前台运行：内部 exec .host/nw（--no-sandbox --disable-gpu
# --user-data-dir=<套件根>/user-data）加载 mixio-app，MixIO 服务在 NW 进程内
# 运行，SIGTERM/SIGINT 由应用自行优雅处理，直接 exec 交给 tini 转发信号。
log "正在启动 MixlyServer（MixIO 服务将在 NW.js 进程内运行）..."
cd "$SERVER_DIR"
exec "./$BIN_NAME"

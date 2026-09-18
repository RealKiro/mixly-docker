#!/bin/sh
# Mixly 服务端容器入口：检测官方运行包 -> 校验架构匹配 -> 修正权限 -> 以非 root 后台启动 -> 守护并转发停止信号
# 官方运行包按机器架构提供（x64 / arm64 / loong64，启动文件同名 mixio），
# 本脚本会在启动前校验运行包架构与机器是否一致，避免用户下错压缩包。
# 注意：mixio 会自我 daemon 化（父进程退出），故不能用 exec 直接启动，见文件末尾说明。
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

# ---------------------------------------------------------------------------
# 启动方式（重要，勿改回 exec）
#
# 运行包内 mixio 的实际行为：
#   start -> spawn 分离的子进程 `mixio debug`（stdout/stderr 重定向到 logs/*.log），
#            父进程仅在启动阶段把日志文件旁路打印到 stdout，
#            读到 "Database Connected!" 后 unref 子进程并 process.exit()
#   debug -> 真正的服务进程，启动时把自身 PID 写入 pid.info
#   stop  -> 读取 pid.info 并向其发送 SIGTERM
#
# 原生部署没问题，但容器里主进程（PID 1 的直接子进程）一退出，
# 整个 PID 命名空间即被销毁：表现为"服务正常启动后过一会儿容器自动停止、
# 日志里没有任何报错"，restart 策略再把它拉起，如此反复。
#
# 因此这里改为：后台启动 -> 保持前台存活守护 -> 收到停止信号时优雅退服。
# ---------------------------------------------------------------------------

# 清理上次运行残留的 pid.info：容器每次启动都是全新的 PID 命名空间，
# 旧 PID 只会让后续 `mixio stop` 误杀无关进程
rm -f "$MIXIO_DIR/pid.info"

on_stop() {
    echo "[INFO] 收到停止信号，正在停止 MixIO ..."
    su-exec mixly:mixly ./mixio stop 2>/dev/null || true
    exit 0
}
trap on_stop TERM INT

# 官方指令：mixio start / stop / help（见 https://gitee.com/mixly2/mixio）
# 其自身会 daemon 化，命令本身很快返回
su-exec mixly:mixly ./mixio start &
START_PID=$!

# 等 pid.info 出现（= 真正的服务进程已起来）；最多等 90 秒（慢机型留足余量）
waited=0
while [ ! -s "$MIXIO_DIR/pid.info" ]; do
    # start 进程已结束且没写出 pid.info -> 未以后台方式运行，按它的退出码结束容器
    kill -0 "$START_PID" 2>/dev/null || break
    [ "$waited" -ge 90 ] && break
    sleep 1
    waited=$((waited + 1))
done

if [ ! -s "$MIXIO_DIR/pid.info" ]; then
    set +e
    wait "$START_PID"
    rc=$?
    set -e
    # 少数 shell 对已回收的子进程返回 127，视作正常结束
    [ "$rc" -eq 127 ] && rc=0
    exit "$rc"
fi

SERVICE_PID="$(tr -dc '0-9' < "$MIXIO_DIR/pid.info" 2>/dev/null || true)"

if [ -z "$SERVICE_PID" ]; then
    echo "[WARN] pid.info 内无有效 PID，容器保持前台存活（MixIO 可能在当前进程内运行）。"
else
    echo "[INFO] MixIO 服务进程 PID: $SERVICE_PID，容器进入守护状态。"
    # 服务进程的输出只写日志文件（原父进程退出后不再旁路），这里跟随最新日志，
    # 让 docker logs / Container Manager 持续可观测
    NEWEST_LOG="$(ls -t "$MIXIO_DIR"/logs/*.log 2>/dev/null | head -n 1 || true)"
    if [ -n "$NEWEST_LOG" ]; then
        tail -f "$NEWEST_LOG" &
    fi
fi

# 守护：服务进程消失则结束容器（交由 restart 策略重新拉起）
while :; do
    if [ -n "$SERVICE_PID" ] && [ ! -d "/proc/$SERVICE_PID" ]; then
        echo "[ERROR] MixIO 服务进程 $SERVICE_PID 已退出，容器结束（若配置 restart 策略会自动重启）。"
        exit 1
    fi
    sleep 10 & wait $!
done

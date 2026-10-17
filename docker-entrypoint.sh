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
    # MixSuite 的可写位置：mixio-app/{storage,logs,config,runtime,store}（服务数据）、
    # mixio-app 本身（pid.info、store 等散落文件/目录）、
    # 套件根目录下的 user-data（Chromium profile）。
    # .host、mixly、mixco、mixmo 等静态大目录保持只读，不做递归 chown。
    #
    # 切记不要 chown 挂载根目录 $SERVER_DIR 本身：解压 / mktemp 出来的根目录
    # 常见 mode 700，属主一旦改成 mixly，宿主机用户会立刻失去访问权限，
    # 表现为「宿主机看不到容器里明明已创建的目录」。
    MIXLY_UID=$(id -u mixly)
    log "root: 开始准备数据目录（套件根=$SERVER_DIR, mixly uid=$MIXLY_UID）"

    # 保证降权后的 mixly 用户能进入套件根目录：mktemp 或严格 umask 解压出来的
    # 根目录可能是 700（属主是宿主机用户），root 能进但 mixly 不能。若不先补权限，
    # 下面「mixly 写入自检」会因无法穿越根目录而误报 EACCES。
    # 只追加「其他用户可读+可进入」，属主不变，不影响宿主机用户的管理权限。
    chmod o+rx "$SERVER_DIR" 2>/dev/null || true

    for _d in "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" \
              "$APP_DIR/runtime" "$APP_DIR/store" "$APP_DIR/config/certs" \
              "$SERVER_DIR/user-data"; do
        mkdir -p "$_d"
        # chown 在 Docker Desktop(WSL2/virtiofs)、NFS/CIFS 等卷上可能静默无效
        # （属主永远呈现为 root），因此不能只靠 chown：权限位必须兜底。
        chown -R mixly:mixly "$_d" 2>/dev/null || true
        # a+rwX：所有用户可读写，目录加执行位。遍历时不跟随符号链接，
        # 不会误改 user-data 里 Chromium 遗留 SingletonLock 指向的目标。
        chmod -R a+rwX "$_d"
    done

    # mixio-app 目录【本身】也必须可写。
    #
    # 这是实测踩到的坑：官方 mixio.js 的 init() 会顺序执行
    #     mixio.js:920  mkdir logs
    #     mixio.js:923  mkdir store      ← 在 mixio-app 下新建
    #     mixio.js:926  mkdir config
    #     mixio.js:992  mkdir config/certs
    # 前三个我们早已预建并授权，唯独 store 漏了；而 chown 在 virtiofs/NFS 上
    # 静默无效（属主仍是 root），mixio-app 保持 755，mixly 用户建不了 store，
    # 于是 init() 在最前面就 EACCES 抛错：
    #     Error: EACCES: permission denied, mkdir '.../mixio-app/store'
    # 该异常被 nw-main.js 写进 runtime/nw-main-error.log，随后启动器探测
    # 超时退出 —— 症状与之前一模一样，但根因完全不同。
    #
    # 因此这里对 mixio-app 本身补 chmod a+rwX：只改这一个目录的权限位、
    # 不递归、不改属主，宿主机用户（属主）权限不受任何影响。
    chown mixly:mixly "$APP_DIR" 2>/dev/null || true
    chmod a+rwX "$APP_DIR"

    # 自检：可写目录必须都存在。缺任何一个都直接报错退出，
    # 把问题暴露在启动阶段，而不是留到后面出现诡异症状。
    for _d in "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" \
              "$APP_DIR/runtime" "$APP_DIR/store" "$APP_DIR/config/certs" \
              "$SERVER_DIR/user-data"; do
        if [ ! -d "$_d" ]; then
            echo "[entrypoint][ERROR] 数据目录创建失败: $_d" >&2
            ls -ld "$SERVER_DIR" "$APP_DIR" >&2 || true
            exit 1
        fi
    done
    log "root: 数据目录就绪: $(ls -d \
        "$APP_DIR/storage" "$APP_DIR/logs" "$APP_DIR/config" \
        "$APP_DIR/runtime" "$APP_DIR/store" "$APP_DIR/config/certs" \
        "$SERVER_DIR/user-data" 2>&1 | tr '\n' ' ')"

    # -------------------------------------------------- 关键：预置 filter.json
    # MixIO 启动链里有若干处「假定文件已存在」的裸同步读写，缺文件即抛异常：
    #
    #   mixio.js:6626  filterPath = <storage>/reserve/filter.json
    #   mixio.js:6756  JSON.parse(fs.readFileSync(filterPath))   ← 无 try/catch
    #
    # 这两行在 async函数 mixioServer() 内，而调用它的是
    #   daemon_start().then(() => startOnce())        （mixio.js:7683，无 .catch）
    # 于是异常被彻底吞掉：不打印、不退出、8443 永不监听，
    # 最终 nw-boot.html 探测 120 次（约 60~120s）后放弃、退出码 0，
    # Docker 重启策略再拉起—— 表现就是「容器每隔一两分钟自己重启一次，
    # docker logs 里什么都看不到」，与当前故障完全一致。
    #
    # 成因：官方仅在 storage 目录【不存在】时才创建 filter.json（mixio.js:929），
    # 但 Docker 下 storage 由本脚本为chown/chmod 而预建，init 便判定
    # 「已初始化过」而跳过创建，6756 行读到 ENOENT 即炸。
    #
    # 对策：在官方代码之前把 filter.json 预置为合法的 {}。
    # 只写官方本身也会写的内容，不改官方包、不改其语义。
    RESERVE_DIR="$APP_DIR/storage/reserve"
    mkdir -p "$RESERVE_DIR"
    chown -R mixly:mixly "$RESERVE_DIR" 2>/dev/null || true
    chmod -R a+rwX "$RESERVE_DIR"
    if [ ! -f "$RESERVE_DIR/filter.json" ]; then
        if printf '{}' > "$RESERVE_DIR/filter.json" 2>/dev/null; then
            # 这个文件由 root 创建（默认 umask 022 → 644）。若 chown 在
            # virtiofs/NFS 上静默失败，属主仍是 root，而官方后续要往里写
            # userName -> bool，mixly 写不进去就会在运行时才炸。
            # 权限位兜底：补成所有用户可读写。
            chmod a+rw "$RESERVE_DIR/filter.json" 2>/dev/null || true
            log "已预置 storage/reserve/filter.json（缺失会让 mixio.js:6756 抛错并静默挂死）"
        else
            warn "预置 filter.json 失败；若服务反复重启请检查 $RESERVE_DIR 是否可写"
        fi
    elif ! grep -q '^[[:space:]]*[{[]' "$RESERVE_DIR/filter.json" 2>/dev/null; then
        # 官方会往里写 userName->bool，必须是合法 JSON，否则同样炸在 6756
        warn "filter.json 内容不是合法 JSON（mixio.js:6756 会抛错），已重置为 {}"
        printf '{}' > "$RESERVE_DIR/filter.json" 2>/dev/null || true
        chmod a+rw "$RESERVE_DIR/filter.json" 2>/dev/null || true
    else
        # 已存在且合法：同样补一次权限位（可能是上一次以 root 身份写的）
        chmod a+rw "$RESERVE_DIR/filter.json" 2>/dev/null || true
    fi

    # zip 解压后常丢失执行位；firstrun.sh 亦要求对这三个文件 chmod +x
    chmod +x "$SERVER_DIR/$BIN_NAME" "$NW_BIN" \
        "$SERVER_DIR/.host/chrome_crashpad_handler" 2>/dev/null || true

    # gosu 不改 HOME；Chromium/NW 的 crashpad、fontconfig 等组件需要可写的 HOME
    export HOME="/tmp/mixly-home"
    mkdir -p "$HOME" && chown mixly:mixly "$HOME"

    # XDG 目录：fontconfig 缓存（"No writable cache directories"）、NSS 数据库
    #（Failed to create .../.local/share/pki/nssdb）都依赖它们可写。
    # MixlyServer 启动器会自行把 HOME 改写为套件根目录，所以除了 XDG 变量，
    # 下面还要在挂载根下预建同名目录并放开权限，双保险。
    for _x in "$HOME/.cache" "$HOME/.config" "$HOME/.local/share" "$HOME/.state"; do
        mkdir -p "$_x"
        chown -R mixly:mixly "$_x" 2>/dev/null || true
        chmod -R a+rwX "$_x"
    done
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_STATE_HOME="$HOME/.state"
    # 兜底：启动器覆盖 HOME 后 fontconfig/NSS 会落到套件根下，这里先铺好可写目录
    for _x in "$SERVER_DIR/.cache" "$SERVER_DIR/.local/share" "$SERVER_DIR/.config"; do
        mkdir -p "$_x"
        chmod -R a+rwX "$_x"
    done

    # 清理上次异常退出可能残留的 ProcessSingleton 文件（属主/权限不对时
    # Chromium 连 unlink 旧 lock 都做不到，会一直报 Permission denied）。
    rm -f "$SERVER_DIR/user-data/SingletonLock" \
          "$SERVER_DIR/user-data/SingletonSocket" \
          "$SERVER_DIR/user-data/SingletonCookie" 2>/dev/null || true

    # -------------------------------------------------- 防御性：清理残留 PID 文件
    # 这两个文件记录的是【宿主机视角的进程 PID】，但它们位于挂载卷里、会跨容器
    # 残留。而 Docker 容器有独立的 PID 空间，两者毫无对应关系。
    #
    # MixIO 启动链自己会按 PID 清理"端口占用"：
    #     mixio.js:7497  freeStaleAdminPort()
    #     mixio.js:7502      读 mixio-app/pid.info → SIGTERM + SIGKILL 该 PID
    #     mixio.js:7290      kill -9 $(netstat ... :18084 ...)   （fuser -k 同效）
    # 这条链只有在 daemon_start() 跑到时才会触发。
    #
    # 【实测证伪的归因，不要再沿这个方向排查】曾把"约 3 秒退出"归因于此：
    # 若 pid.info 旧 PID 复用为 Xvfb 的 PID，Xvfb 被 SIGKILL → DISPLAY 失效
    # → Chromium 窗口销毁 → XGetWindowAttributes failed for window 0 → NW.js
    # 「所有窗口关闭」自动退出（退出码 0）。
    # 但后续实测否定了它：pid.info 内容为 203，而该容器内最高 PID 仅 146，
    # kill 只会得到 ESRCH；且 Xvfb 全程存活、无任何被杀记录。
    # 换言之：这是【防御性】清理（成本为零、去掉一个不确定因素），
    # 不是"约 3 秒退出"的根因。真正的窗口层故障请用 MIXLY_NW_SELFTEST=1 /
    # MIXLY_DIRECT_NW=1 取证，见下方启动段。
    for _pf in "$APP_DIR/pid.info" "$APP_DIR/runtime/mixio-backend.pid"; do
        if [ -e "$_pf" ]; then
            _pv=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]' || true)
            rm -f "$_pf" 2>/dev/null || true
            log "已清理残留 PID 文件 $(basename "$_pf")（内容: ${_pv:-空}）"
            log "  ↑ 该 PID 属宿主机视角，与容器 PID 空间无对应关系（防御性清理）"
        fi
    done

    # 实测 mixly 对 user-data 的写入能力：Chromium 启动时要在 profile 里建
    # SingletonLock，写不进去会直接 Abort（表现为容器反复重启、
    # "Failed to create ... SingletonLock: Permission denied"）。
    # chown 在 Docker Desktop(WSL2/virtiofs)/NFS/CIFS 卷上静默无效，
    # 仅靠 chmod a+rwX 兜底，这里必须真验一次，把问题暴露在启动阶段。
    if ! gosu mixly:mixly sh -c "touch '$SERVER_DIR/user-data/.entrypoint-write-test'" 2>/dev/null; then
        echo "[entrypoint][ERROR] mixly 用户无法写入 $SERVER_DIR/user-data" >&2
        echo "[entrypoint][ERROR] Chromium 将无法创建 SingletonLock，容器会反复重启。" >&2
        ls -ld "$SERVER_DIR" "$SERVER_DIR/user-data" >&2 || true
        echo "[entrypoint][ERROR] 若 Docker 跑在 Windows/macOS Desktop 或 NFS 卷上，" >&2
        echo "[entrypoint][ERROR] 属主语义不受支持，请确认使用 v2.0.1+ 镜像（chmod 兜底）。" >&2
        exit 1
    fi
    rm -f "$SERVER_DIR/user-data/.entrypoint-write-test" 2>/dev/null || true

    # 实测 mixly 对 mixio-app 目录【本身】的写入能力。
    # 官方 mixio.js 的 init() 会在这里顺序 mkdir logs/store/config/config/certs
    # （mixio.js:920/923/926/992）。子目录我们能预建，但目录本身的写权限
    # 决定官方能否新建条目——chown 在 virtiofs/NFS 上无效时这里就会失败，
    # 表现为 init() 在最前面 EACCES、整份日志只有一句
    # "Error: EACCES: permission denied, mkdir '.../mixio-app/store'"。
    # 提前探针可把此类故障变成启动期的明确报错，而不是 120 秒后静默重启。
    if ! gosu mixly:mixly sh -c "touch '$APP_DIR/.entrypoint-write-test'" 2>/dev/null; then
        echo "[entrypoint][ERROR] mixly 用户无法在 $APP_DIR 下创建文件" >&2
        echo "[entrypoint][ERROR] 官方 mixio.js 的 init() 需要在此新建 store/ 等目录，" >&2
        echo "[entrypoint][ERROR] 写不进去会导致 MixIO 加载失败（见 nw-main-error.log）。" >&2
        ls -ld "$APP_DIR" >&2 || true
        echo "[entrypoint][ERROR] 在宿主机执行: chmod a+rwX '$APP_DIR'" >&2
        exit 1
    fi
    rm -f "$APP_DIR/.entrypoint-write-test" 2>/dev/null || true

    # 实测 mixly 对 storage/reserve 的写入能力：SQLite 建库、filter.json、
    # 1.db..8.db 模板复制都在这里进行。
    if ! gosu mixly:mixly sh -c "touch '$APP_DIR/storage/reserve/.entrypoint-write-test'" 2>/dev/null; then
        echo "[entrypoint][ERROR] mixly 用户无法写入 $APP_DIR/storage/reserve" >&2
        echo "[entrypoint][ERROR] SQLite 数据库与 filter.json 将无法创建。" >&2
        ls -ld "$APP_DIR/storage" "$APP_DIR/storage/reserve" >&2 || true
        exit 1
    fi
    rm -f "$APP_DIR/storage/reserve/.entrypoint-write-test" 2>/dev/null || true

    # 轮换上一次残留的 nw-main-error.log。
    # 该文件在上一次失败后会留在挂载卷里。不清掉的话，容器每次重启都会把
    # 上一次的旧错误重新打印一遍（watcher 与退出分支都会读它），
    # 用户会误以为「又出了一个新错误」。这里改名留存为 .prev，
    # 既避免误导，又不丢证据；新的一次性错误由 watcher 实时捕获。
    if [ -s "$APP_DIR/runtime/nw-main-error.log" ]; then
        mv -f "$APP_DIR/runtime/nw-main-error.log" \
              "$APP_DIR/runtime/nw-main-error.log.prev" 2>/dev/null || true
    fi

    exec gosu mixly:mixly "$0" "$@"
fi

# 非 root 直接运行（--user）时尽量修执行位，失败不致命
chmod +x "$SERVER_DIR/$BIN_NAME" "$NW_BIN" 2>/dev/null || true

# ---------------------------------------------------------------- Xvfb 虚拟显示
# NW.js 需要 X11 才能建窗口；服务端部署用 Xvfb 兜底。浏览器访问不依赖它。
DISPLAY_NUM="${MIXLY_DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

# Chromium 共享内存检查：/dev/shm 默认仅 64MB，NW.js 渲染进程在空间不足时会
# 异常退出，且不产生任何应用层日志——表现就是容器每隔一两分钟静默重启一次
# （退出码 137/139）。这里主动检测并给出明确修复方式。
_shm_kb=$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')
if [ -n "$_shm_kb" ] && [ "$_shm_kb" -lt 262144 ] 2>/dev/null; then
    log "警告: /dev/shm 仅 $((_shm_kb / 1024))MB（需≥256MB），Chromium 渲染进程可能异常退出"
    log "警告: 请加 --shm-size=1g 启动容器（compose 用 shm_size: '1gb'），否则可能出现静默重启"
fi
# 同一容器重启后 PID 命名空间是全新的，上一次的 X socket/lock 已是残留
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

# -ac 关掉 X 访问控制：Xvfb 由 root 分支启动（gosu 降权前的同一进程），
# 而降权后的 mixly 用户是另一个 uid。无 -ac 时能否连上取决于 X 服务器的
# host-based 控制实现，加上它彻底消除这个变量（-nolisten tcp 保证不开 TCP 端口，
# 只听 unix socket，安全性不受影响）。
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp -ac &
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

# Xvfb 存活监控：Xvfb 若在 MixlyServer 运行期间死亡，DISPLAY 会失效、
# Chromium 窗口被销毁、NW.js 随即以退出码 0 结束（所有窗口关闭即退出）。
# 这是一个通用兜底监控，不再特指某一种根因——"约 3 秒退出"已实测与它无关
# （那次 Xvfb 全程存活），保留它是为了在真的发生时不留下空白日志。
( while kill -0 "$XVFB_PID" 2>/dev/null; do
      sleep 2
  done
  if [ -n "${MIXLY_PID:-}" ] && kill -0 "$MIXLY_PID" 2>/dev/null; then
      echo "[entrypoint][ERROR] =============================================" >&2
      echo "[entrypoint][ERROR] Xvfb (PID $XVFB_PID) 在 MixlyServer 运行期间被杀！" >&2
      echo "[entrypoint][ERROR] 这会导致 DISPLAY 失效、Chromium 窗口被销毁，" >&2
      echo "[entrypoint][ERROR] NW.js 随即以退出码 0 结束（所有窗口关闭即退出）。" >&2
      echo "[entrypoint][ERROR] 请检查：dmesg | grep -i 'killed process'" >&2
      echo "[entrypoint][ERROR] =============================================" >&2
  fi ) &

# ---------------------------------------------------------------- 启动服务
# MixlyServer 是官方壳：设好 LD_LIBRARY_PATH 后 fork + execv .host/nw
# （--nwapp=mixio-app --user-data-dir=… --ozone-platform=x11 --no-sandbox
#  --disable-gpu --in-process-gpu …），父进程负责打印检查进度并等待端口就绪。
# nw 加载 mixio-app 后，nw-main.js 会设 MIXIO_NW_SPAWN=1 再同进程 require mixio.js，
# 使其走 args=['debug'] 的前台分支（daemon_start + startOnce），服务不 spawn
# 子进程、与容器同生命周期，SIGTERM 由 tini 转发、应用自行优雅退出。
#
# 已知的启动器局限（容器场景）：
#   * 父进程 stdout 在管道下是【全缓冲】，其 "Checking ports"、
#     "Starting NW runtime"、"Loading MixIO service" 等进度会随缓冲区丢失，
#     连 "Port conflict detected" 也看不到 —— 日志里没有它们不代表没执行。
#   * 带 "Continue? [y/N]" 交互询问，非 TTY 下读 stdin 立即 EOF。
# 需要 Chromium 内部日志时用 MIXLY_DIRECT_NW=1 绕过它（见下方）。
#
# MIXIO_DISABLE_NTP=1：容器内非 root 无法绑定特权端口 123（仅告警，但会刷日志），
# 显式跳过 NTP 仿真（mixio.js 认这个开关）。
# MIXIO_SHELL_DAEMON=1：官方给"前台运行"的开关，双保险（NW 路径本已前台）。
export MIXIO_SHELL_DAEMON=1
export MIXIO_DISABLE_NTP=1

# 启动前端口快照：MixIO 的 daemon_start() 第一步就是探测 18084，若判定被占，
# 会触发一串按 PID 的 SIGKILL（见上方「清理残留 PID 文件」说明）。
# 这里把实况打出来，便于区分「真的被占」与「checkPort 误判」。
_port_snap=$(ss -lntp 2>/dev/null | grep -E ':(8443|18084|1883|8082|8083|8084|8086)[[:space:]]' || true)
if [ -n "$_port_snap" ]; then
    log "启动前端口状态（发现监听中的端口）："
    echo "$_port_snap" | sed 's/^/[entrypoint]   /'
    log "↑ 若其中没有本容器应有的进程，请检查是否用了 --network host 或端口被其他程序占用"
else
    log "启动前端口状态: 8443/18084/1883/8082-8086 均空闲"
fi
log "当前进程: $(ps -o pid,ppid,comm -e 2>/dev/null | head -12 | sed 's/^/[entrypoint]   /' | tr '\n' '|')"

log "正在启动 MixlyServer（MixIO 服务将在 NW.js 进程内运行）..."
log "访问入口: https://<本机IP>:8443（HTTPS，自签证书）/ 管理: https://<本机IP>:18084"

# ------------------------------------------- NW.js 调用参数（与官方启动器一致）
# 从官方 MixlyServer 二进制里提取到的真实调用形式（见其字符串表）：
#   LD_LIBRARY_PATH=<suite>/.host/lib:<suite>/.host
#   --nwapp=<mixio-app>  --user-data-dir=<suite>/user-data
#   --ozone-platform=x11 --ozone-platform-hint=x11 --no-sandbox
#   --disable-setuid-sandbox --disable-gpu-sandbox --disable-gpu
#   --disable-dev-shm-usage --in-process-gpu
# 启动器本身是 fork + execv，父进程负责打印 "Checking ports / Starting NW
# runtime / Loading MixIO service" 等进度。但父进程的 stdout 在管道下是【全
# 缓冲】的，容器非 TTY 时这些消息会在父进程退出时随缓冲区一起丢掉 ——
# 这就是日志里看不到任何启动器进度、也看不到 "Port conflict detected" 的原因。
# 启动器还带 "Continue? [y/N]" 交互询问，非 TTY 下读 stdin 立即 EOF。
NW_APP="$APP_DIR"
NW_USERDATA="$SERVER_DIR/user-data"
NW_LIB="$SERVER_DIR/.host/lib:$SERVER_DIR/.host"
NW_COMMON_ARGS="--nwapp=$NW_APP --user-data-dir=$NW_USERDATA --ozone-platform=x11 --ozone-platform-hint=x11 --no-sandbox --disable-setuid-sandbox --disable-gpu-sandbox --disable-gpu --disable-dev-shm-usage --in-process-gpu"

# 直连模式的公共参数：与官方启动器一致的核心集合 + Chromium 内部日志。
# 与 NW_COMMON_ARGS 的差别：默认【不】强制 ozone（让 Chromium 自动探测 X11），
# 且追加 --enable-logging=stderr，把「窗口句柄为何是 0 / 为何退出」交给
# Chromium 自己说。策略 3 才补回 ozone 两个开关。
# 注意（v2.1.0 实测确认）：NW_COMMON_ARGS 里的两个 ozone 开关在 Xvfb 下会
# 使 Chromium 窗口创建失败（window 0 → 约 3 秒退出码 0），这就是官方启动器
# 路径在容器里活不下来的根因；NW_DIRECT_BASE 去掉它们后稳定运行。
NW_DIRECT_BASE="--nwapp=$NW_APP --user-data-dir=$NW_USERDATA --no-sandbox --disable-setuid-sandbox --disable-gpu-sandbox --disable-gpu --disable-dev-shm-usage --in-process-gpu --enable-logging=stderr"

# ------------------------------------------- NW.js 最小窗口自检（可复用函数）
# 目的：把「NW.js/Chromium 在本容器能否创建窗口」与「MixSuite 应用层是否有问题」
# 一刀切开。CI 冒烟测试用桩替换了 MixlyServer，真实 Chromium 从未被验证过，
# 所以 CI 全绿不等于镜像依赖齐备。
# v2.2.0 起改为双探针（根因由 v2.1.0 实测定位）：探针 A 用默认策略参数（无
# ozone）——这才是「本容器能否建窗口」的正确答案；探针 B 补回官方 ozone 参数
# 做对照，直接把根因差异打出来。
# 用法：run_nw_selftest <超时秒数>
# 调用方：
#   * MIXLY_NW_SELFTEST=1 显式自检（交互式取证）
#   * 短命-0 退出时的 auto_forensics（自动取证，用户无需执行任何命令）
run_nw_selftest() {
    _st_timeout="${1:-40}"
    ST="$APP_DIR/runtime/nw-selftest"
    rm -rf "$ST"
    mkdir -p "$ST"
    cat > "$ST/package.json" <<'PKG'
{
  "name": "nw-selftest",
  "main": "index.html",
  "window": { "width": 400, "height": 300, "show": true }
}
PKG
    cat > "$ST/index.html" <<'HTM'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>nw-selftest</title></head>
<body><h3>NW.js window OK</h3><script>
(function () {
  function done() {
    try {
      var fs = require('fs');
      fs.writeFileSync(require('path').join(__dirname, 'selftest.ok'), 'ok\n');
    } catch (e) {}
    try { nw.App.quit(); } catch (e2) {}
  }
  if (document.readyState === 'complete' || document.readyState === 'interactive') setTimeout(done, 200);
  else window.addEventListener('DOMContentLoaded', function () { setTimeout(done, 200); });
})();
</script></body></html>
HTM
    chmod -R a+rwX "$ST" 2>/dev/null || true
    log "[自检] 正在以最小 NW.js 应用测试窗口创建（约 ${_st_timeout}s 上限）..."
    log "[自检] X 显示: $DISPLAY；Xvfb PID: $XVFB_PID"

    # 探针 A（主探针）：与默认策略一致——【不指定 ozone】，让 Chromium 自动
    # 探测 X11。v2.1.0 实测：这才是本容器能创建窗口的参数组合。
    _st_rc=0
    ( cd "$ST" && LD_LIBRARY_PATH="$NW_LIB" timeout "$_st_timeout" "$SERVER_DIR/.host/nw" \
        --nwapp="$ST" --user-data-dir="$SERVER_DIR/user-data" \
        --no-sandbox --disable-setuid-sandbox --disable-gpu-sandbox --disable-gpu \
        --disable-dev-shm-usage --in-process-gpu \
        --enable-logging=stderr ) || _st_rc=$?
    if [ -f "$ST/selftest.ok" ]; then
        log "[自检] ✅ 通过（无 ozone）：NW.js 能在本容器创建窗口并加载页面（退出码 $_st_rc）。"
        log "[自检] 结论：镜像运行时依赖齐备；若 MixIO 仍异常，问题在应用层或启动参数。"
    else
        log "[自检] ❌ 失败（无 ozone）：窗口未创建成功（退出码 $_st_rc）。"
        log "[自检] 结论：NW.js/Chromium 在本容器建不了窗口，属镜像运行时/环境问题。"
        log "[自检] 请把本段完整日志（含上面的 stderr）反馈，以便补依赖。"
    fi

    # 探针 B（ozone 对照）：补回官方启动器默认传的两个开关。
    # v2.1.0 实测定位的根因：Xvfb 下 --ozone-platform=x11 使 Chromium 窗口
    # 创建失败（window 0 → 所有窗口关闭 → 退出码 0，约 3 秒）。本探针把
    # 「有 ozone 建不了 / 无 ozone 能建」的差异直接打出来，避免再靠猜。
    rm -f "$ST/selftest.ok"
    _oz_rc=0
    ( cd "$ST" && LD_LIBRARY_PATH="$NW_LIB" timeout 10 "$SERVER_DIR/.host/nw" \
        --nwapp="$ST" --user-data-dir="$SERVER_DIR/user-data" \
        --ozone-platform=x11 --ozone-platform-hint=x11 --no-sandbox \
        --disable-setuid-sandbox --disable-gpu-sandbox --disable-gpu \
        --disable-dev-shm-usage --in-process-gpu \
        --enable-logging=stderr ) || _oz_rc=$?
    if [ -f "$ST/selftest.ok" ]; then
        log "[自检] ozone 对照探针：通过（退出码 $_oz_rc）——本环境下 ozone 无害。"
    else
        log "[自检] ozone 对照探针：失败（退出码 $_oz_rc）——加上官方 ozone 参数就建不了窗口。"
        log "[自检]   若探针 A 通过而本探针失败，即复现了 v2.1.0 定位的根因："
        log "[自检]   --ozone-platform=x11 在 Xvfb 下导致窗口创建失败（window 0）。"
    fi

    log "[自检] 关键线索：若上方出现 'XGetWindowAttributes failed' / 'cannot open display'"
    log "[自检] / 'Failed to connect to the bus' 之外的其他错误，即为直接原因。"
    # X 服务器能力证据：窗口建失败时，visual/扩展缺失是最常见的环境根因。
    # 注意：Xvfb 无 ARGB visual、缺 RANDR/DAMAGE 等都会让 Chromium 建窗失败，
    # 而这类信息只有 xdpyinfo 能直接给出。
    if command -v xdpyinfo >/dev/null 2>&1; then
        log "[自检] --- xdpyinfo（X 服务器 visual 与扩展）---"
        xdpyinfo -display "$DISPLAY" 2>&1 | sed -n '1,45p' | sed 's/^/[自检]   /' || true
    fi
}

# ------------------------------------------- 可选：NW.js 最小窗口自检（显式模式）
# 目的：把「NW.js/Chromium 在本容器能否创建窗口」与「MixSuite 应用层是否有问题」
# 一刀切开。CI 冒烟测试用桩替换了 MixlyServer，真实 Chromium 从未被验证过，
# 所以 CI 全绿不等于镜像依赖齐备。
# 用法：docker run -e MIXLY_NW_SELFTEST=1 ...，容器只做自检然后退出。
if [ "${MIXLY_NW_SELFTEST:-0}" = "1" ]; then
    run_nw_selftest 40
    exit 0
fi

# ------------------------------------------- 可选：直连 NW.js（跳过官方启动器）
# 官方 MixlyServer 是 fork+execv 的壳：父进程打印进度但 stdout 全缓冲会丢，
# 且带 "Continue? [y/N]" 询问（非 TTY 下 EOF）。当 MixIO 在 120s 内起不来、
# 或进程几秒就退出时，启动器这一层只会让日志更少。
# MIXLY_DIRECT_NW=1 时直接 exec .host/nw，并额外打开 Chromium 内部日志
# （--enable-logging=stderr），把「窗口为什么是 0 / 为什么退出」打出来。
if [ "${MIXLY_DIRECT_NW:-0}" = "1" ]; then
    log "[直连模式] 跳过官方 MixlyServer 启动器，直接运行 .host/nw"
    log "[直连模式] 已追加 --enable-logging=stderr，Chromium 内部日志会全部输出"
    log "[直连模式] 若要恢复官方启动器，去掉 -e MIXLY_DIRECT_NW=1 即可"
    cd "$SERVER_DIR"
    trap 'kill -TERM "$MIXLY_PID" 2>/dev/null || true' TERM INT
    _t0=$(date +%s)
    # 用 exec 让子 shell 被 nw 自身替换：否则 MIXLY_PID 只是子 shell 的 PID，
    # 上面的 trap 发 TERM 会打在壳上而 nw 收不到，只能等容器被整体 SIGKILL。
    ( export LD_LIBRARY_PATH="$NW_LIB"
      # shellcheck disable=SC2086
      exec "$SERVER_DIR/.host/nw" $NW_COMMON_ARGS --enable-logging=stderr ) &
    MIXLY_PID=$!
    _rc=0
    wait "$MIXLY_PID" || _rc=$?
    _uptime=$(( $(date +%s) - _t0 ))
    log "NW.js 进程已退出，退出码: $_rc（本次存活 ${_uptime}s）"
    exit "$_rc"
fi

# ------------------------------------------- MixIO 日志转发 + 就绪状态播报
# NW.js 会吞掉 mixio.js 的 console.log，它的真实启动过程只写在
# mixio-app/logs/*.log 里，而没有这层转发，用户在 docker logs 里只能看到
# 一片 dbus 噪音，完全看不出服务到底卡在哪一步。这里把日志实时转发到
# stdout，并在未就绪时定期播报端口状态，让 docker logs 本身即可判定。
mkdir -p "$APP_DIR/logs"
# 只在前台身份启动转发：root 分支会 gosu 重跑本脚本，若不加此判断会起两个 tail，
# 同一份日志被重复输出两遍。
if [ "$(id -u)" != "0" ]; then
    if ls "$APP_DIR/logs"/*.log >/dev/null 2>&1; then
        ( tail -n 0 -F "$APP_DIR/logs"/*.log 2>/dev/null \
            | sed -u 's/^/[mixio] /' ) &
    else
        ( # 日志文件稍后才创建：等它出现再开始跟随
          _waited_log=0
          while [ "$_waited_log" -lt 120 ]; do
              sleep 1
              ls "$APP_DIR/logs"/*.log >/dev/null 2>&1 && break
              _waited_log=$((_waited_log + 1))
          done
          ls "$APP_DIR/logs"/*.log >/dev/null 2>&1 && \
            tail -n 0 -F "$APP_DIR/logs"/*.log 2>/dev/null | sed -u 's/^/[mixio] /' ) &
    fi
    log "已启用 MixIO 日志转发（日志行前缀 [mixio]，日志文件出现后即自动跟随）"

    # ---- 捕获 nw-main-error.log：mixio.js 加载失败的唯一落盘证据 ----
    # nw-main.js 在 require('./mixio.js') 抛错时，会把完整 stack 写入
    # mixio-app/runtime/nw-main-error.log。这是「顶层 require 失败」这类
    # 致命错误的唯一可观测点，但它不会出现在 docker logs 里，必须主动跟随。
    # 已实测过的两类内容：
    #   EACCES: permission denied, mkdir '.../mixio-app/store'
    #       → init() 建目录失败，属 chown 无效导致 mixio-app 不可写
    #   Cannot find module 'node:sqlite'
    #       → NW.js 内置 Node 版本过旧，需反馈官方
    # 按内容分流诊断，不要把每种错误都套同一句结论。
    ( _werr=0
      while [ "$_werr" -lt 180 ]; do
          sleep 1
          if [ -s "$APP_DIR/runtime/nw-main-error.log" ]; then
              _werr_text=$(cat "$APP_DIR/runtime/nw-main-error.log" 2>/dev/null)
              echo "" >&2
              echo "=========================================================" >&2
              echo "[entrypoint][ERROR] MixIO 加载失败！以下是 nw-main.js 记录的完整错误：" >&2
              echo "=========================================================" >&2
              echo "$_werr_text" >&2
              echo "=========================================================" >&2
              case "$_werr_text" in
                  *EACCES*|*"permission denied"*)
                      echo "[entrypoint][ERROR] 这是【文件权限】问题：mixio.js 的 init() 无法创建数据目录。" >&2
                      echo "[entrypoint][ERROR] 在宿主机上对套件根执行：chmod -R a+rwX <mixio-app 所在目录>" >&2
                      echo "[entrypoint][ERROR] 若挂载来源是 NFS/CIFS/Windows 共享，请改成本地目录或 ext4。" >&2
                      ;;
                  *"node:sqlite"*|*"Cannot find module"*)
                      echo "[entrypoint][ERROR] 常见原因：NW.js 内置 Node 版本不支持 node:sqlite" >&2
                      echo "[entrypoint][ERROR] （mixio.js 依赖 SQLite 存储引擎）。请把本段日志反馈给官方。" >&2
                      ;;
                  *)
                      echo "[entrypoint][ERROR] 请把本段完整日志反馈，以便定位。" >&2
                      ;;
              esac
              echo "=========================================================" >&2
              break
          fi
          _werr=$((_werr + 1))
      done ) &
fi

# 就绪播报：40s 起每 30s 检查一次 8443，未监听就明确提示（含排查位置）
#
# 时间窗口很关键：nw-boot.html 最多探测 120 次 x 500ms（约 60s），受网络/CPU
# 影响实测可到 120s+，超时后应用主动退出码 0。所以在它自杀之前必须
# 把「为什么没起来」讲清楚，否则重启循环里只有一片空白。
( _n=0
  while [ "$_n" -lt 20 ]; do
      sleep 30
      if curl -ksf -o /dev/null --max-time 4 https://127.0.0.1:8443/ 2>/dev/null; then
          log "就绪检查: 8443 已有 MixIO 在监听，可用 https://<本机IP>:8443 访问"
          exit 0
      fi
      _n=$((_n + 1))
      [ "$_n" = "1" ] && log "就绪检查: 启动已 40s，8443 仍未监听（首次启动要初始化数据库，请耐心等待）"
      [ "$_n" -eq 2 ] && log "就绪检查: 80s 仍未监听；若日志无[mixio] 输出说明日志目录未生成，见 README FAQ Q10"
      [ "$_n" -ge 3 ] && [ "$_n" -le 4 ] && \
          log "就绪检查: $((_n * 30))s 仍未监听。NW.js 最多等待约 120s，超时后会自行退出并被重启策略拉起"
      if [ "$_n" -ge 3 ]; then
          # 直接把可观测证据打出来：用户不必再手动 docker exec
          if [ -s "$APP_DIR/runtime/nw-main-error.log" ]; then
              log "诊断: 检测到 runtime/nw-main-error.log（MixIO 加载失败），完整内容已打印在上方"
          fi
          log "诊断: storage=$(ls "$APP_DIR/storage" 2>/dev/null | tr '\n' ' ')reserve=$(ls "$APP_DIR/storage/reserve" 2>/dev/null | tr '\n' ' ')"
          log "诊断: mixio-app 权限=$(ls -ld "$APP_DIR" 2>/dev/null)（mixly 需能在其下新建目录）"
      fi
  done
  log "就绪检查: 10 分钟内 8443 始终未监听。请执行："
  log "  docker exec <容器> sh -c 'cat /opt/mixly_server/mixio-app/logs/*.log'"
  log "  docker exec <容器> sh -c 'cat /opt/mixly_server/mixio-app/runtime/nw-main-error.log'"
  log "  docker exec <容器> sh -c 'netstat -lntp | grep -E \"8443|18084\"'" ) &

# ---------------------------------------------------------------- 启动策略
# 根因已定位（v2.1.0 实测确认，2026-10-17 用户日志）：
#   官方启动器传给 .host/nw 的 --ozone-platform=x11 --ozone-platform-hint=x11
#   在 Xvfb 下会使 Chromium 连【隐藏窗口】都创建失败（stderr:
#   XGetWindowAttributes failed for window 0）→ 所有窗口被关闭 →
#   NW.js 以退出码 0 结束，全程约 3 秒（MixIO 各服务其实已就绪，
#   8443 探针有响应——死的只是窗口层）。
#   同一环境、同一运行包，【不指定 ozone】（Chromium 自动探测 X11）时
#   完全正常：1883/8082-8086/8443/18084 全部监听，容器长期存活。
# 因此默认策略 = 直连 .host/nw 且不指定 ozone（策略 1）；官方启动器及其余
# 直连变体保留在轮换里，供环境不同的部署回退：
#   * 连续短命-0 失败时，每次重启自动切换一种启动方式（共 4 种，轮换）；
#   * 其它退出（正常停止/崩溃/超时，即非短命-0）重置计数，下次仍从策略 1 开始；
#   * 计数文件在挂载卷内（runtime/boot-attempt），跨重启保留；
#   * MIXLY_STRATEGY=1~4 可显式固定策略（优先级高于计数器，固定期间不动计数器）；
#   * 显式设置 MIXLY_NW_SELFTEST / MIXLY_DIRECT_NW 时完全听用户的，不介入。
# 每次启动都打印所用策略；短命失败时自动执行 auto_forensics 取证。
ATTEMPT_FILE="$APP_DIR/runtime/boot-attempt"
PORT_PROBE_STATE="$APP_DIR/runtime/port-probe.state"
STRATEGY=1
STRATEGY_DESC="直连 .host/nw（不指定 ozone，Chromium 自动探测 X11；实测默认）"

# 8443 快速探针（1s 间隔，启动时就开始）：记录 HTTPS 服务首次响应的时刻。
# 短命退出时它是关键证据——服务到底起没起来过，直接决定排查方向：
# 起来了 = 窗口/渲染层问题；从未起来 = MixIO 初始化问题。
: > "$PORT_PROBE_STATE" 2>/dev/null || true
( _pp_first=0; _pp_cnt=0; _pp_i=0
  while [ "$_pp_i" -lt 600 ]; do
      if curl -ksf -o /dev/null --max-time 2 https://127.0.0.1:8443/ 2>/dev/null; then
          _pp_cnt=$((_pp_cnt + 1))
          if [ "$_pp_first" = 0 ]; then
              _pp_first=$(date +%s)
              log "端口探针: 8443 首次响应（$(date -d @"$_pp_first" '+%H:%M:%S' 2>/dev/null || echo "$_pp_first")），MixIO HTTPS 服务已就绪"
          fi
          echo "up $_pp_first $_pp_cnt" > "$PORT_PROBE_STATE" 2>/dev/null || true
      fi
      sleep 1
      _pp_i=$((_pp_i + 1))
  done ) &

if [ "${MIXLY_NW_SELFTEST:-0}" != "1" ] && [ "${MIXLY_DIRECT_NW:-0}" != "1" ]; then
    # MIXLY_STRATEGY=1~4：显式固定启动策略，优先级高于计数器。
    # 用途：测试锁定，或环境特殊必须固定某种方式（如必须走官方启动器的端口
    # 预检查）。固定期间不读写计数器，避免打乱后续的自动轮换状态。
    _STRATEGY_PINNED=0
    if [ -n "${MIXLY_STRATEGY:-}" ]; then
        case "$MIXLY_STRATEGY" in
            1|2|3|4) STRATEGY="$MIXLY_STRATEGY"; _STRATEGY_PINNED=1 ;;
            *) warn "MIXLY_STRATEGY 只能是 1~4（当前值: $MIXLY_STRATEGY），已忽略，改用计数器" ;;
        esac
    fi
    if [ "$_STRATEGY_PINNED" != "1" ]; then
        _prev=0
        if [ -f "$ATTEMPT_FILE" ]; then
            _prev=$(tr -dc '0-9' < "$ATTEMPT_FILE" 2>/dev/null || true)
            [ -n "$_prev" ] || _prev=0
            [ "$_prev" -gt 4 ] && _prev=4
        fi
        STRATEGY=$((_prev + 1))
        [ "$STRATEGY" -gt 4 ] && STRATEGY=1
    fi
    case "$STRATEGY" in
        1) STRATEGY_DESC="直连 .host/nw（不指定 ozone，Chromium 自动探测 X11；实测默认）" ;;
        2) STRATEGY_DESC="官方启动器 MixlyServer（stdbuf 行缓冲；Xvfb 下 ozone 参数可致 window 0）" ;;
        3) STRATEGY_DESC="直连 .host/nw（强制 ozone x11，与官方启动器参数一致）" ;;
        4) STRATEGY_DESC="直连 .host/nw（关闭原生窗口遮挡检测 CalculateNativeWinOcclusion）" ;;
    esac
    if [ "$_STRATEGY_PINNED" != "1" ]; then
        echo "$STRATEGY" > "$ATTEMPT_FILE" 2>/dev/null || true
    fi
fi
log "启动策略 $STRATEGY/4: $STRATEGY_DESC"

# 按策略启动；统一设置 MIXLY_PID 供 trap / wait 使用
launch_strategy() {
    cd "$SERVER_DIR"
    case "$STRATEGY" in
        1|3|4)
            _extra=""
            case "$STRATEGY" in
                3) _extra="--ozone-platform=x11 --ozone-platform-hint=x11" ;;
                4) _extra="--disable-features=CalculateNativeWinOcclusion" ;;
            esac
            log "直连模式: 跳过官方启动器，直接运行 .host/nw（附加参数: ${_extra:-无}）"
            ( export LD_LIBRARY_PATH="$NW_LIB"
              # shellcheck disable=SC2086
              exec "$SERVER_DIR/.host/nw" $NW_DIRECT_BASE $_extra ) &
            ;;
        2)
            # stdbuf 强制行缓冲：官方启动器的 stdout 在管道下本是全缓冲，
            # "Checking ports / Starting NW runtime / Loading MixIO service /
            #  MixlyServer exited before becoming ready" 等关键进度会随缓冲区
            # 整体丢失，连 "Port conflict detected" 都看不到。LD_PRELOAD 与
            # _STDBUF_* 环境变量会经 exec 传给 fork 出的 nw 子进程，node 侧
            # console.log（如 "[INFO] MixIO 服务器正在运行，PID: ..."）也能实时可见。
            # 注意（v2.1.0 实测）：官方启动器传给 nw 的 ozone 两个开关在 Xvfb
            # 下会导致窗口创建失败（window 0 → 约 3 秒退出码 0），因此它只是
            # 轮换后备，不是默认方式。
            if command -v stdbuf >/dev/null 2>&1; then
                log "通过 stdbuf -oL -eL 启动官方 MixlyServer（强制行缓冲，启动器进度不再丢失）"
                stdbuf -oL -eL ./"$BIN_NAME" &
            else
                warn "stdbuf 不可用，直接启动官方 MixlyServer（其进度输出可能因全缓冲丢失）"
                ./"$BIN_NAME" &
            fi
            ;;
    esac
    MIXLY_PID=$!
}

# ---------------------------------------------------------------- 自动取证
# 短命-0 退出时自动执行：把原本需要用户手动 docker exec 的取证全部打印到
# docker logs。用户要做的只有一件事：把「自动取证开始」到结束之间的日志反馈。
auto_forensics() {
    log "==================== 自动取证开始 ===================="

    log "--- 1) 8443 端口探针（1s 间隔，启动时就开始）---"
    if [ -f "$PORT_PROBE_STATE" ]; then
        _pps=$(cat "$PORT_PROBE_STATE" 2>/dev/null || true)
        case "$_pps" in
            up*) log "    HTTPS 服务曾就绪：$_pps（格式: up 首次响应Unix时间 累计响应次数）" ;;
            *)   log "    HTTPS 服务从未就绪（探针状态: ${_pps:-无记录}）" ;;
        esac
    else
        log "    无探针记录"
    fi

    log "--- 2) mixio-app/logs 末 15 行 ---"
    if ls "$APP_DIR/logs"/*.log >/dev/null 2>&1; then
        tail -n 15 "$APP_DIR/logs"/*.log 2>/dev/null | head -60 | sed 's/^/[entrypoint]   /' || true
    else
        log "    （无日志文件 —— mixio.js 未走到写日志那一步，或日志目录未生成）"
    fi

    log "--- 3) runtime/nw-main-error.log ---"
    if [ -s "$APP_DIR/runtime/nw-main-error.log" ]; then
        cat "$APP_DIR/runtime/nw-main-error.log" 2>/dev/null | sed 's/^/[entrypoint]   /' || true
    else
        log "    空/不存在 = mixio.js 顶层加载成功，故障在 NW 壳/窗口层"
    fi

    log "--- 4) 进程与 Xvfb 状态 ---"
    ps -o pid,ppid,stat,comm -e 2>/dev/null | head -20 | sed 's/^/[entrypoint]   /' || true
    if kill -0 "$XVFB_PID" 2>/dev/null; then
        log "    Xvfb (PID $XVFB_PID) 存活"
    else
        log "    Xvfb (PID $XVFB_PID) 已死亡！DISPLAY 失效会直接导致窗口销毁、NW.js 以退出码 0 结束"
    fi

    log "--- 5) NW.js 最小窗口自检（隔离环境问题与应用层问题）---"
    run_nw_selftest 20

    log "==================== 自动取证结束 ===================="
    log "请把「自动取证开始」到「自动取证结束」之间的完整日志反馈，即可定位根因。"
}

cd "$SERVER_DIR"
# 这里刻意【不用 exec】：保留退出码并转发信号。MixlyServer 静默退出是当前最需要
# 诊断的场景（容器 running→进程没了→重启策略拉起，日志里看不到任何原因），
# 退出码是判断崩溃类型的第一手证据：139=段错误 134=abort 143=正常停止。
# _STOP_REQUESTED：区分「进程自己短命退出」与「docker stop 导致的退出」——
# 后者不该触发窗口层故障的自动取证（用户手动停止是正常流程）。
_STOP_REQUESTED=0
trap '_STOP_REQUESTED=1; kill -TERM "$MIXLY_PID" 2>/dev/null || true' TERM INT
_t0=$(date +%s)
launch_strategy
# 脚本顶部有 set -e，而 wait 在子进程非零退出时返回非零 —— 必须用 || 捕获，
# 否则 set -e 会在此直接终止脚本，下面的退出码解读永远不会执行。
_rc=0
wait "$MIXLY_PID" || _rc=$?
_uptime=$(( $(date +%s) - _t0 ))
log "MixlyServer 进程已退出，退出码: $_rc（本次存活 ${_uptime}s）"

# 短命-0 判定：自己退的（非停止信号触发）且 15s 内以退出码 0 结束。
# 这是 NW.js 窗口层故障的签名（窗口提前销毁 → 所有窗口关闭即退出）。
_FAST_FAIL=0
if [ "$_rc" = "0" ] && [ "$_uptime" -lt 15 ] && [ "$_STOP_REQUESTED" != "1" ]; then
    _FAST_FAIL=1
fi

# 策略计数：只有「短命-0」推进策略；其它退出（正常停止/崩溃/超时）重置，
# 下次重启仍从默认策略（直连无 ozone）开始。MIXLY_STRATEGY 固定期间不动计数器。
if [ "$_FAST_FAIL" = "1" ]; then
    :
elif [ "${_STRATEGY_PINNED:-0}" != "1" ]; then
    echo 0 > "$ATTEMPT_FILE" 2>/dev/null || true
fi

case "$_rc" in
    0)   log "退出码 0 = 应用主动退出，并非'正常退出'。"
         if [ "$_STOP_REQUESTED" = "1" ]; then
             log "  ▸ 本次是收到停止信号后的退出（docker stop / restart），属正常流程。"
         elif [ "$_FAST_FAIL" = "1" ]; then
             log "  ▸ 存活仅 ${_uptime}s（远小于 120s），排除'就绪探测超时'。"
             log "  ▸ 这是 NW.js「所有窗口被关闭即自动退出」：窗口提前销毁，"
             log "    而 nw-boot.html 自身永远不会主动退出（其 onTimeout 只改文案）。"
             log "  ▸ 已确认的事实：mixio.js 加载成功、init() 通过（本次无新"
             log "    nw-main-error.log），所以故障在 NW 壳/窗口层，不在 MixIO 初始化。"
             log "  ▸ 关键证据在 stderr：'XGetWindowAttributes failed for window 0'"
             log "    —— 窗口句柄是 0，说明窗口从未真正创建成功，随后被销毁。"
             log "  ▸ 本次启动策略 $STRATEGY/4: $STRATEGY_DESC"
             log "  ▸ 以下为自动取证输出（无需手动执行任何命令）："
             auto_forensics
            # 记录本次短命失败：下次重启自动切换启动策略（轮换 1→2→3→4→1）
            [ "${_STRATEGY_PINNED:-0}" = "1" ] || echo "$STRATEGY" > "$ATTEMPT_FILE" 2>/dev/null || true
             _next=$((STRATEGY + 1))
             [ "$_next" -gt 4 ] && _next=1
             log "  ▸ 已记录本次失败；下次重启自动切换策略 $_next/4。"
             log "  ▸ 若某种策略下容器持续存活（超过 15s），计数器自动重置，"
             log "    之后仍从默认策略（直连无 ozone）开始——不需要你做任何操作。"
         else
             log "  ▸ 最常见原因：启动器就绪探测（约 120 次 x 500ms）超时后放弃。"
             log "  ▸ 这几乎总是意味着 MixIO 内部初始化抛错且异常被吞掉。"
         fi
         if [ -s "$APP_DIR/runtime/nw-main-error.log" ]; then
             log "       >>> 已有 runtime/nw-main-error.log，其内容已打印在上方"
         elif [ -s "$APP_DIR/runtime/nw-main-error.log.prev" ]; then
             log "       >>> 本次未生成新错误日志，但存在上一次的 nw-main-error.log.prev"
             log "       >>> docker exec <容器> sh -c 'cat /opt/mixly_server/mixio-app/runtime/nw-main-error.log.prev'"
         else
             log "       >>> 若上方无任何 [mixio] 输出，说明 mixio.js 加载后在init/daemon_start 阶段静默失败"
             log "       >>> 依次执行以下命令取证（把输出反馈给官方）："
             log "           docker exec <容器> sh -c 'cat /opt/mixly_server/mixio-app/runtime/nw-main-error.log'"
             log "           docker exec <容器> sh -c 'ls -laR /opt/mixly_server/mixio-app/storage'"
             log "           docker exec <容器> sh -c 'netstat -lntp'"
         fi ;;
    139) log "退出码 139 = SIGSEGV（段错误崩溃）。常见原因：NW.js/Chromium 在无显示环境下崩溃；可尝试给容器加 --shm-size=1g" ;;
    134) log "退出码 134 = SIGABRT（断言失败/abort 崩溃）。建议查看上方 [mixio] 日志的最后几行" ;;
    143) log "退出码 143 = SIGTERM（收到停止信号，正常退出）" ;;
    *)   log "退出码 $_rc 属非预期退出，容器会被重启策略拉起；请把上方日志连同本行一起反馈" ;;
esac
exit "$_rc"

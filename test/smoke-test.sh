#!/usr/bin/env bash
# 入口脚本冒烟测试：无需官方 MixSuite 运行包，用假运行包 + ELF 桩二进制
# 校验容器启动链路。用法: smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?用法: smoke-test.sh <image>}"
PASS=0

ok() { echo "✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "❌ $1"; exit 1; }

# 生成静态 ELF 桩（不依赖容器内 glibc 环境）；放在 .host/nw 供架构校验
make_stub() { # $1 = 输出路径
    cat > /tmp/mixly-stub.c <<'EOF'
#include <stdio.h>
int main(void) { puts("stub-nw-ok"); return 0; }
EOF
    gcc -static -o "$1" /tmp/mixly-stub.c
}

# 组装假 MixSuite 包: $1=目录 $2=arm64 时把 .host/nw 的 e_machine 伪造成 aarch64
make_pkg() {
    local dir="$1" fake="$2"
    mkdir -p "$dir/.host" "$dir/mixio-app" "$dir/mixly"
    make_stub "$dir/.host/nw"
    if [ "$fake" = "arm64" ]; then
        printf '\xb7\x00' | dd of="$dir/.host/nw" bs=1 seek=18 conv=notrunc status=none
    fi
    # MixlyServer 桩：打印标记后前台常驻（MixSuite 版 MixlyServer 前台运行、不 daemon 化），
    # 捕获 TERM/INT 模拟官方应用的优雅退出。
    # 同时模拟 MixIO 的真实可观测性：NW.js 会吞掉它的 console.log，真实日志写在
    # mixio-app/logs/*.log 里——入口脚本必须把它转发到 stdout。
    # MIXLY_STUB_EXIT=N 时启动 N 秒后以该码退出，用于验证退出码捕获链路。
    cat > "$dir/MixlyServer" <<'STUB'
#!/bin/sh
echo "[INFO] stub MixlyServer running (foreground)"
LOG="$PWD/mixio-app/logs/stub-mixio.log"
mkdir -p "$PWD/mixio-app/logs"
sleep 1   # 给入口脚本的 tail 转发留出启动时间（tail -n 0 只跟随后续写入）
echo "[INFO] MixIO 服务器已成功启动。 / MixIO server is running now." >> "$LOG"
trap 'echo "[INFO] stub received stop signal, exiting"; exit 0' TERM INT
if [ -n "${MIXLY_STUB_EXIT:-}" ]; then
    sleep 2
    echo "[INFO] stub simulating crash, exit $MIXLY_STUB_EXIT" >> "$LOG"
    exit "$MIXLY_STUB_EXIT"
fi
while :; do sleep 5 & wait $!; done
STUB
    echo '{}' > "$dir/mixio-app/package.json"
    echo '// stub mixio.js' > "$dir/mixio-app/mixio.js"
    echo '{"version":"4.0.0-test"}' > "$dir/mixly/version.json"
    chmod +x "$dir/MixlyServer" "$dir/.host/nw"
}

# 等待容器日志出现指定内容（轮询，避免固定 sleep 拖慢/抖动）
wait_log() { # $1=cid $2=pattern $3=timeout_seconds
    local cid="$1" pat="$2" timeout="$3" i=0
    while [ "$i" -lt "$timeout" ]; do
        docker logs "$cid" 2>&1 | grep -q "$pat" && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

echo "=== T1 缺包检测 ==="
out=$(docker run --rm "$IMAGE" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "T1 无运行包时应非零退出"
echo "$out" | grep -q "未检测到 Mixly 官方运行包" || fail "T1 未输出放置指引"
echo "$out" | grep -q "MixSuite-linux-x64" || fail "T1 放置指引未提及 MixSuite 包名"
ok "T1 缺包时输出 MixSuite 放置指引并退出 (exit=$rc)"

echo "=== T2 启动链路（架构匹配的 x64 桩：Xvfb + 前台 exec + 数据目录）==="
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t2_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t2_fail="桩二进制未被 exec 执行"
if [ -z "$t2_fail" ]; then
    c_logs=$(docker logs "$cid" 2>&1)
    echo "$c_logs" | grep -q "运行包架构校验通过" || t2_fail="架构校验未通过"
    echo "$c_logs" | grep -q "Xvfb 虚拟显示已就绪" || t2_fail="Xvfb 未就绪"
    # CI 的 /dev/shm 是 Docker 默认 64MB，正好覆盖"共享内存不足"这条告警路径：
    # 该检测缺失会导致 NW.js 在用户机器上静默重启而无任何提示。
    echo "$c_logs" | grep -q "/dev/shm 仅" \
        || t2_fail="未检出 /dev/shm 共享内存不足（CI 默认 64MB，应打出警告）"
fi
if [ -z "$t2_fail" ]; then
    # 回归检查：宿主机必须仍能访问挂载源。入口脚本若 chown 挂载根目录
    # （解压/mktemp 出来的根目录常见 mode 700），会把宿主用户锁在外面，
    # 导致下面所有 -d 检查因 EACCES 而失败（曾真实发生过）。
    if [ ! -r "$tmp" ] || [ ! -x "$tmp" ]; then
        t2_fail="宿主机已无法访问挂载源 $tmp（入口脚本错误地 chown 了挂载根目录？）"
    fi
fi
if [ -z "$t2_fail" ]; then
    for d in storage logs config runtime; do
        if [ ! -d "$tmp/mixio-app/$d" ]; then
            t2_fail="未创建数据目录 mixio-app/$d"
            break
        fi
    done
fi
if [ -z "$t2_fail" ] && [ ! -d "$tmp/user-data" ]; then
    # 目录名混入回车符（脚本被 CRLF 污染）时肉眼不可见，单独给出明确报错
    if [ -d "$tmp/user-data"$'\r' ]; then
        t2_fail="user-data 目录名混入了回车符（脚本被 CRLF 污染）"
    else
        t2_fail="未创建 user-data 目录"
    fi
fi
if [ -z "$t2_fail" ]; then
    uid=$(stat -c '%u' "$tmp/mixio-app/storage")
    [ "$uid" != "0" ] || t2_fail="数据目录仍为 root 属主"
fi
if [ -n "$t2_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -30 || true
    echo "----- 容器内 /opt/mixly_server 视图（docker exec）-----"
    docker exec "$cid" ls -la /opt/mixly_server/ 2>&1 || true
    echo "----- 宿主机挂载源 $tmp 视图（cat -A 暴露不可见字符）-----"
    ls -la "$tmp" 2>&1 | cat -A || true
    echo "----- 容器挂载配置 -----"
    docker inspect -f '{{json .Mounts}}' "$cid" 2>&1 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t2_fail" ] || fail "T2 $t2_fail"
ok "T2 校验/chmod/chown/Xvfb/exec 全链路通过（数据目录 uid=$uid，非 root）"

echo "=== T2b chown 无效场景的 chmod 兜底（Docker Desktop/NFS 卷语义）==="
# Docker Desktop(WSL2/virtiofs)、NFS/CIFS 卷上 chown 静默无效（属主永远 root），
# 旧逻辑只靠 chown，导致 mixly 写不进 user-data → Chromium 建不了 SingletonLock
# → 容器反复重启。入口脚本必须用 chmod a+rwX 兜底。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
mkdir -p "$tmp/user-data"
touch "$tmp/user-data/leftover"          # 预置 root 属主的残留文件
chmod 755 "$tmp/user-data"               # 预置 other 只读（典型挂载卷语义）
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t2b_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t2b_fail="桩二进制未被 exec 执行"
if [ -z "$t2b_fail" ]; then
    mode=$(stat -c '%a' "$tmp/user-data")
    case "$mode" in
        *2|*3|*6|*7) : ;;
        *) t2b_fail="user-data 的 other 位仍不可写（mode=$mode），chmod 兜底未生效" ;;
    esac
fi
if [ -z "$t2b_fail" ] && [ ! -d "$tmp/.cache" ]; then
    # fontconfig 缓存/NSS 库的落点：启动器会覆盖 HOME 为套件根，
    # 入口脚本需在套件根下预建可写的 .cache / .local/share / .config，
    # 否则 Chromium 刷 "No writable cache directories"。
    t2b_fail="未预建套件根下的 .cache（fontconfig 缓存目录，Chromium 会报 No writable cache directories）"
fi
if [ -z "$t2b_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "无法写入.*user-data" \
        && t2b_fail="入口脚本的写入自检未通过"
fi
if [ -n "$t2b_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -20 || true
    echo "----- 宿主机 user-data 视图 -----"
    ls -la "$tmp/user-data" 2>&1 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t2b_fail" ] || fail "T2b $t2b_fail"
ok "T2b 预置 root 属主 user-data 时 chmod 兜底生效，容器正常启动"

echo "=== T3 架构不匹配（x86_64 机器 + arm64 桩）==="
tmp=$(mktemp -d)
make_pkg "$tmp" arm64
out=$(docker run --rm -v "$tmp:/opt/mixly_server" "$IMAGE" 2>&1) && rc=0 || rc=$?
echo "$out"
[ "$rc" -ne 0 ] || fail "T3 架构不匹配时应非零退出"
echo "$out" | grep -q "运行包与机器架构不匹配" || fail "T3 缺少不匹配提示"
rm -rf "$tmp" 2>/dev/null || true
ok "T3 下错架构包被明确拦截"

echo "=== T4 镜像元数据 ==="
ep=$(docker inspect -f '{{json .Config.Entrypoint}}' "$IMAGE")
echo "$ep" | grep -q "tini" || fail "T4 Entrypoint 未使用 tini: $ep"
ports=$(docker inspect -f '{{json .Config.ExposedPorts}}' "$IMAGE")
for p in 8443 18084 1883 8082 8083 8084 8086; do
    echo "$ports" | grep -q "\"$p/tcp\"" || fail "T4 缺少端口声明 $p: $ports"
done
echo "$ports" | grep -q "\"8080/tcp\"" && fail "T4 MixSuite 强制 HTTPS，不应再暴露 8080" || true
# 健康检查：NW 壳活着不代表 MixIO 就绪，这个探针让 docker ps 如实显示服务状态
hc=$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")
echo "$hc" | grep -q "curl" || fail "T4 缺少 8443 健康检查: $hc"
echo "$hc" | grep -q "127.0.0.1:8443" || fail "T4 健康检查未探测 8443: $hc"
# 诊断工具：容器内排查（看端口/进程/日志）需要它们
for t in curl ps netstat; do
    docker run --rm --entrypoint sh "$IMAGE" -c "command -v $t" >/dev/null 2>&1 \
        || fail "T4 镜像缺少诊断工具 $t"
done
ok "T4 Entrypoint(tini)、7 个端口、8443 健康检查与诊断工具齐备（无 8080）"

echo "=== T5 前台运行保活 + docker stop 优雅退出 ==="
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t5_fail=""
sleep 8
[ "$(docker inspect -f '{{.State.Running}}' "$cid")" = "true" ] || t5_fail="前台运行中容器不应自行停止"
docker stop -t 15 "$cid" >/dev/null 2>&1 || true
if [ -z "$t5_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "stub received stop signal" || t5_fail="停止时未走优雅退服"
fi
if [ -n "$t5_fail" ]; then
    echo "----- 容器日志（末 30 行）-----"
    docker logs "$cid" 2>&1 | tail -30 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
# 容器内以 mixly 用户写入的文件可能让 runner 用户无法删除；清理失败无所谓（runner 为一次性环境）
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t5_fail" ] || fail "T5 $t5_fail"
ok "T5 前台运行容器保持存活，docker stop 优雅退服"

echo "=== T6 MixIO 日志转发 + 崩溃退出码捕获 ==="
# 场景：NW 壳静默崩溃 → 容器被重启策略拉起 → 没有 exec 就拿不到退出码，
# 而 MixIO 的日志只在文件里，用户在 docker logs 里什么都看不到。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_STUB_EXIT=42 -v "$tmp:/opt/mixly_server" "$IMAGE")
t6_fail=""
wait_log "$cid" "退出码: 42" 60 || t6_fail="未捕获子进程退出码 42（入口脚本可能仍用 exec 启动）"
if [ -z "$t6_fail" ]; then
    # 用崩溃前最后一条日志做断言：tail -n 0 从文件末尾开始跟，桩启动瞬间写的
    # 那几行可能落在 tail 就绪之前，只有稍后追加的行一定会被转发出来。
    docker logs "$cid" 2>&1 | grep -q "\[mixio\].*stub simulating crash" \
        || t6_fail="MixIO 日志未转发到 stdout（缺少 [mixio] 前缀行）"
fi
if [ -z "$t6_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "已启用 MixIO 日志转发" \
        || t6_fail="入口脚本未声明启用日志转发"
fi
if [ -n "$t6_fail" ]; then
    echo "----- 容器日志（末 30 行）-----"
    docker logs "$cid" 2>&1 | tail -30 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t6_fail" ] || fail "T6 $t6_fail"
ok "T6 MixIO 日志转发到 stdout，崩溃退出码 42 被捕获并解读"

echo "=== T7 预置 filter.json（mixio.js:6756 静默挂死的根因回归）==="
# 官方 mixio.js:929 只在 storage 目录【不存在】时才创建 storage/reserve/filter.json，
# 而 mixio.js:6756 是裸的 JSON.parse(fs.readFileSync(filterPath))，无 try/catch；
# 调用它的 daemon_start().then(() => startOnce())（L7683）也没有 .catch。
# 于是 Docker 下只要 storage 被预建（为chown/chmod），官方就跳过 filter.json，
# 6756 读到 ENOENT 抛错 → 异常被彻底吞掉 → 8443 永不监听 →
# nw-boot.html 探测约 120s 后放弃、退出码 0 → 重启策略拉起。
# 外部表现：容器每隔一两分钟自动重启，docker logs 一片空白。
# 入口脚本必须在启动官方代码之前把 filter.json 预置为合法的 {}。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t7_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t7_fail="桩二进制未被 exec 执行"
if [ -z "$t7_fail" ] && [ ! -f "$tmp/mixio-app/storage/reserve/filter.json" ]; then
    t7_fail="未预置 storage/reserve/filter.json（缺失会让 mixio.js:6756 抛错并静默挂死）"
fi
if [ -z "$t7_fail" ]; then
    # 必须是合法 JSON 对象：官方会往里写 userName -> bool
    grep -q '^[[:space:]]*[{[]' "$tmp/mixio-app/storage/reserve/filter.json" \
        || t7_fail="预置的 filter.json 不是合法 JSON 对象"
fi
if [ -z "$t7_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "已预置 storage/reserve/filter.json" \
        || t7_fail="入口脚本未声明预置 filter.json"
fi
if [ -z "$t7_fail" ]; then
    # reserve 目录本身也必须对 mixly 可写（官方要往里复制 1.db..8.db 并写 filter.json）
    if ! docker exec "$cid" sh -c \
        "gosu mixly sh -c 'touch /opt/mixly_server/mixio-app/storage/reserve/.t7'" >/dev/null 2>&1; then
        t7_fail="mixly 无法写入 storage/reserve（filter.json 与 reserve DB 无法创建）"
    else
        docker exec "$cid" rm -f /opt/mixly_server/mixio-app/storage/reserve/.t7 >/dev/null 2>&1 || true
    fi
fi
if [ -n "$t7_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- 宿主机 storage 视图 -----"
    ls -laR "$tmp/mixio-app/storage" 2>&1 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t7_fail" ] || fail "T7 $t7_fail"
ok "T7 filter.json 已预置且 reserve 目录对 mixly 可写（静默挂死根因已覆盖）"

echo "=== T8 nw-main-error.log 捕获（MixIO 加载失败的唯一证据）==="
# nw-main.js 在 require('./mixio.js') 抛错时把完整 stack 写入
# mixio-app/runtime/nw-main-error.log，但它不会出现在 docker logs 里。
# 若入口脚本不主动捕获，用户就只能看到「容器重启但零日志」。
# 这里让桩模拟顶层 require 失败，验证该文件内容被打印到容器日志。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
# 覆盖桩：启动前写入 nw-main-error.log，模拟 mixio.js 顶层 require 失败
cat > "$tmp/MixlyServer" <<'STUB'
#!/bin/sh
echo "[INFO] stub MixlyServer running (foreground)"
mkdir -p "$PWD/mixio-app/runtime"
cat > "$PWD/mixio-app/runtime/nw-main-error.log" <<'ERR'
[nw-main] failed to load mixio.js in-process: Error: Cannot find module 'node:sqlite'
Require stack:
- /opt/mixly_server/mixio-app/sqlite-native.js
ERR
sleep 30
STUB
chmod +x "$tmp/MixlyServer"
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t8_fail=""
wait_log "$cid" "MixIO 加载失败" 60 \
    || t8_fail="未捕获 runtime/nw-main-error.log（MixIO 加载失败时docker logs 无任何线索）"
if [ -z "$t8_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "Cannot find module 'node:sqlite'" \
        || t8_fail="错误详情未完整打印到容器日志"
fi
if [ -z "$t8_fail" ]; then
    docker logs "$cid" 2>&1 | grep -q "node:sqlite" \
        || t8_fail="未提示 node:sqlite 兼容性这一常见原因"
fi
if [ -n "$t8_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t8_fail" ] || fail "T8 $t8_fail"
ok "T8 nw-main-error.log 被捕获并打印（含 node:sqlite 兼容性提示）"

echo "=== T9 退出码 0 的诊断指引 ==="
# 退出码 0 极易被误读为「正常退出」，实际是就绪探测超时后应用自杀。
# 入口脚本必须明确指出这一点并给出取证命令。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
t9_fail=""
wait_log "$cid" "退出码: 0" 60 || t9_fail="未捕获退出码 0"
if [ -z "$t9_fail" ]; then
    logs=$(docker logs "$cid" 2>&1)
    echo "$logs" | grep -q "就绪探测" \
        || t9_fail="未说明退出码 0 实为就绪探测超时"
    echo "$logs" | grep -q "nw-main-error.log" \
        || t9_fail="未给出取证命令（nw-main-error.log）"
fi
if [ -n "$t9_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t9_fail" ] || fail "T9 $t9_fail"
ok "T9 退出码 0 被正确解读为就绪探测超时并给出取证路径"

echo "=== T10 mixio-app 本身可写 + store/config-certs 预建（EACCES 根因回归）==="
# 实测踩到的坑（v2.0.6 仍在复现）：官方 mixio.js 的 init() 顺序执行
#     L920 mkdir logs   L923 mkdir store   L926 mkdir config   L992 mkdir config/certs
# 入口脚本此前只授权了 storage/logs/config/runtime/user-data，漏了 store，
# 且只 chown 了 mixio-app 而没 chmod —— chown 在 Docker Desktop(WSL2/virtiofs)/
# NFS/CIFS 上静默无效，mixio-app 保持 root:root 755，mixly(uid 996) 建不了 store：
#     Error: EACCES: permission denied, mkdir '.../mixio-app/store'
# 该异常被 nw-main.js 写进 runtime/nw-main-error.log，启动器随后探测超时退出。
# 本用例锁定：mixio-app 目录本身对 mixly 可写、store 与 config/certs 已预建。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t10_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t10_fail="桩二进制未被 exec 执行"
if [ -z "$t10_fail" ]; then
    [ -d "$tmp/mixio-app/store" ] \
        || t10_fail="未预建 mixio-app/store（官方 init() 要在 mixio-app 下新建它）"
fi
if [ -z "$t10_fail" ]; then
    [ -d "$tmp/mixio-app/config/certs" ] \
        || t10_fail="未预建 mixio-app/config/certs（官方要往里写默认证书）"
fi
if [ -z "$t10_fail" ]; then
    # 关键：mixio-app 目录【本身】必须允许 mixly 新建条目。
    # chown 在 virtiofs 上无效时，只有 chmod a+rwX 能救这一种情况。
    if ! docker exec "$cid" sh -c \
        "gosu mixly sh -c 'touch /opt/mixly_server/mixio-app/.t10'" >/dev/null 2>&1; then
        t10_fail="mixly 无法在 mixio-app 下新建文件（store 等目录将创建失败，EACCES）"
    else
        docker exec "$cid" rm -f /opt/mixly_server/mixio-app/.t10 >/dev/null 2>&1 || true
    fi
fi
if [ -z "$t10_fail" ]; then
    # store 与 config/certs 也必须对 mixly 可写（官方往里写用户文件/证书）
    for _d in store config/certs; do
        if ! docker exec "$cid" sh -c \
            "gosu mixly sh -c 'touch /opt/mixly_server/mixio-app/$_d/.t10'" >/dev/null 2>&1; then
            t10_fail="mixly 无法写入 mixio-app/$_d"
            break
        fi
        docker exec "$cid" rm -f "/opt/mixly_server/mixio-app/$_d/.t10" >/dev/null 2>&1 || true
    done
fi
if [ -n "$t10_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- 宿主机 mixio-app 视图 -----"
    ls -la "$tmp/mixio-app" 2>&1 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t10_fail" ] || fail "T10 $t10_fail"
ok "T10 mixio-app 本身可写、store/config-certs 已预建且对 mixly 可写"

echo "=== T11 EACCES 错误的定向诊断 ==="
# nw-main-error.log 的内容决定诊断方向：权限类错误必须指向 chmod/文件系统，
# 而不是一律甩给 node:sqlite。曾因一律归因 node:sqlite 而多绕了数轮。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cat > "$tmp/MixlyServer" <<'STUB'
#!/bin/sh
echo "[INFO] stub MixlyServer running (foreground)"
mkdir -p "$PWD/mixio-app/runtime"
cat > "$PWD/mixio-app/runtime/nw-main-error.log" <<'ERR'
Error: EACCES: permission denied, mkdir '/opt/mixly_server/mixio-app/store'
    at Object.mkdirSync (node:fs:1651:26)
    at init (/opt/mixly_server/mixio-app/mixio.js:923:12)
ERR
sleep 30
STUB
chmod +x "$tmp/MixlyServer"
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t11_fail=""
wait_log "$cid" "MixIO 加载失败" 60 || t11_fail="未捕获 runtime/nw-main-error.log"
if [ -z "$t11_fail" ]; then
    logs=$(docker logs "$cid" 2>&1)
    echo "$logs" | grep -q "EACCES: permission denied, mkdir" \
        || t11_fail="错误详情未完整打印"
    echo "$logs" | grep -q "文件权限" \
        || t11_fail="未识别为文件权限类错误（会把用户误导到 node:sqlite）"
    echo "$logs" | grep -q "chmod -R a+rwX" \
        || t11_fail="未给出 chmod 修复命令"
fi
if [ -n "$t11_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t11_fail" ] || fail "T11 $t11_fail"
ok "T11 EACCES 被定向诊断为权限问题并给出 chmod 修复命令"

echo "=== T12 陈旧 nw-main-error.log 轮换（避免旧错误反复误导）==="
# nw-main-error.log 在上一次失败后会留在挂载卷里。若不轮换，容器每次重启
# 都会把【上一次】的旧错误重新打印一遍，用户会误以为出现了新故障。
# 入口脚本应改名为 .prev 留存，新错误由 watcher 实时捕获。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
mkdir -p "$tmp/mixio-app/runtime"
echo "STALE-ERROR-FROM-PREVIOUS-RUN" > "$tmp/mixio-app/runtime/nw-main-error.log"
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
t12_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t12_fail="桩二进制未被 exec 执行"
if [ -z "$t12_fail" ]; then
    # 陈旧错误不得作为「本次加载失败」被打印
    if docker logs "$cid" 2>&1 | grep -q "STALE-ERROR-FROM-PREVIOUS-RUN"; then
        t12_fail="上一次的陈旧错误被当成新错误重复打印（会误导排查方向）"
    fi
fi
if [ -z "$t12_fail" ]; then
    # 但证据不能丢：必须留存为 .prev
    [ -f "$tmp/mixio-app/runtime/nw-main-error.log.prev" ] \
        || t12_fail="陈旧错误未被留存为 nw-main-error.log.prev（证据丢失）"
fi
if [ -n "$t12_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- runtime 目录 -----"
    ls -la "$tmp/mixio-app/runtime" 2>&1 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t12_fail" ] || fail "T12 $t12_fail"
ok "T12 陈旧 nw-main-error.log 被轮换为 .prev，不再重复误导"

echo "🎉 冒烟测试全部通过: $PASS/12"

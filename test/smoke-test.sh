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

# 判断容器日志是否包含指定内容（ERE）。
#
# 千万不要写成 `docker logs "$cid" 2>&1 | grep -q "$pat"`：本脚本开头有
# set -o pipefail，而 grep -q 一旦命中就立刻退出，此时 docker logs 仍在
# 往管道写，就会收到 SIGPIPE（退出码 141）；pipefail 把 141 当作整条管道
# 失败，于是「日志里明明有这行」却判成没有 —— 实测 T7 就这样假失败过
# （匹配串在日志中段；在末段时 grep 读完全部才退出，反而不会触发，
# 所以同一个 bug 会随日志长短随机出现，极难复现）。
#
# 这里先把日志整体读进变量再用 bash 内置正则匹配：没有管道、没有子进程
# 提前退出，彻底消除这一类竞态。
log_has() { # $1=cid $2=ERE
    local _l
    _l=$(docker logs "$1" 2>&1 || true)
    [[ $_l =~ $2 ]]
}

# 等待容器日志出现指定内容（轮询，避免固定 sleep 拖慢/抖动）
wait_log() { # $1=cid $2=pattern $3=timeout_seconds
    local cid="$1" pat="$2" timeout="$3" i=0
    while [ "$i" -lt "$timeout" ]; do
        log_has "$cid" "$pat" && return 0
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t2_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t2_fail="桩二进制未被 exec 执行"
if [ -z "$t2_fail" ]; then
    # 统一走 log_has：`echo "$c_logs" | grep -q` 与 `docker logs | grep -q`
    # 是同一条 pipefail+SIGPIPE 链路（echo 量小时不易触发，但仍是隐患）
    log_has "$cid" "运行包架构校验通过" || t2_fail="架构校验未通过"
    log_has "$cid" "Xvfb 虚拟显示已就绪" || t2_fail="Xvfb 未就绪"
    # CI 的 /dev/shm 是 Docker 默认 64MB，正好覆盖"共享内存不足"这条告警路径：
    # 该检测缺失会导致 NW.js 在用户机器上静默重启而无任何提示。
    log_has "$cid" "/dev/shm 仅" \
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
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
    # 期望【不】出现：grep 不命中时会读完全部输入，不会触发 SIGPIPE，
    # 但为一致性与可读性仍统一走 log_has
    log_has "$cid" "无法写入.*user-data" \
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t5_fail=""
sleep 8
[ "$(docker inspect -f '{{.State.Running}}' "$cid")" = "true" ] || t5_fail="前台运行中容器不应自行停止"
docker stop -t 15 "$cid" >/dev/null 2>&1 || true
if [ -z "$t5_fail" ]; then
    log_has "$cid" "stub received stop signal" || t5_fail="停止时未走优雅退服"
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -e MIXLY_STUB_EXIT=42 -v "$tmp:/opt/mixly_server" "$IMAGE")
t6_fail=""
wait_log "$cid" "退出码: 42" 60 || t6_fail="未捕获子进程退出码 42（入口脚本可能仍用 exec 启动）"
if [ -z "$t6_fail" ]; then
    # 用崩溃前最后一条日志做断言：tail -n 0 从文件末尾开始跟，桩启动瞬间写的
    # 那几行可能落在 tail 就绪之前，只有稍后追加的行一定会被转发出来。
    log_has "$cid" "\[mixio\].*stub simulating crash" \
        || t6_fail="MixIO 日志未转发到 stdout（缺少 [mixio] 前缀行）"
fi
if [ -z "$t6_fail" ]; then
    log_has "$cid" "已启用 MixIO 日志转发" \
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
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
    # 注意：必须用 log_has 而不是 `docker logs | grep -q`。
    # 本脚本有 set -o pipefail，grep -q 命中即退出会让 docker logs 收到
    # SIGPIPE(141)，管道状态变为 141，这里就会假失败（实测发生过）。
    log_has "$cid" "已预置 storage/reserve/filter.json" \
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t8_fail=""
wait_log "$cid" "MixIO 加载失败" 60 \
    || t8_fail="未捕获 runtime/nw-main-error.log（MixIO 加载失败时docker logs 无任何线索）"
if [ -z "$t8_fail" ]; then
    log_has "$cid" "Cannot find module 'node:sqlite'" \
        || t8_fail="错误详情未完整打印到容器日志"
fi
if [ -z "$t8_fail" ]; then
    log_has "$cid" "node:sqlite" \
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

echo "=== T9 退出码 0 的诊断指引（按存活时长分流）==="
# 退出码 0 极易被误读为「正常退出」。入口脚本必须明确指出这不是正常退出，
# 并按【存活时长】分流：短命(<15s)=NW.js 窗口提前销毁；长命(≈120s)=就绪探测超时。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_STRATEGY=2 -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
t9_fail=""
wait_log "$cid" "退出码: 0" 60 || t9_fail="未捕获退出码 0"
if [ -z "$t9_fail" ]; then
    # 同样必须用 log_has：`echo "$logs" | grep -q` 也是同一条 pipefail+SIGPIPE 链路
    log_has "$cid" "并非'正常退出'" \
        || t9_fail="未明确指出退出码 0 不是正常退出"
    # 桩 sleep 2 即退出，必然命中「短命」分支
    log_has "$cid" "存活仅" \
        || t9_fail="未打印本次存活时长（无法区分两条失败路径）"
    log_has "$cid" "所有窗口被关闭即自动退出" \
        || t9_fail="未说明短命退出对应 NW.js 窗口销毁机制"
    log_has "$cid" "nw-main-error.log" \
        || t9_fail="未给出取证命令（nw-main-error.log）"
fi
if [ -n "$t9_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t9_fail" ] || fail "T9 $t9_fail"
ok "T9 退出码 0 按存活时长分流诊断并给出取证路径"

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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t11_fail=""
wait_log "$cid" "MixIO 加载失败" 60 || t11_fail="未捕获 runtime/nw-main-error.log"
if [ -z "$t11_fail" ]; then
    log_has "$cid" "EACCES: permission denied, mkdir" \
        || t11_fail="错误详情未完整打印"
    log_has "$cid" "文件权限" \
        || t11_fail="未识别为文件权限类错误（会把用户误导到 node:sqlite）"
    log_has "$cid" "chmod -R a\+rwX" \
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
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t12_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t12_fail="桩二进制未被 exec 执行"
if [ -z "$t12_fail" ]; then
    # 陈旧错误不得作为「本次加载失败」被打印（期望【不】命中）
    if log_has "$cid" "STALE-ERROR-FROM-PREVIOUS-RUN"; then
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

echo "=== T13 清理残留 PID 文件（防止 MixIO 误杀 Xvfb）==="
# v2.0.7 实测：mixio.js 加载成功后，daemon_start() → freeStaleAdminPort()
# 会读 mixio-app/pid.info 里的旧 PID 并 SIGKILL（mixio.js:7502），
# 另有 kill -9 $(netstat ... :18084 ...)（mixio.js:7290）。
# pid.info 写在挂载卷里、跨容器残留，而容器 PID 空间独立，旧 PID 极可能
# 已复用为本次 Xvfb/tini 的 PID → 误杀 → 窗口销毁 → 约 3 秒退出码 0。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
mkdir -p "$tmp/mixio-app/runtime"
echo "12345" > "$tmp/mixio-app/pid.info"
echo "12346" > "$tmp/mixio-app/runtime/mixio-backend.pid"
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t13_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t13_fail="桩二进制未被 exec 执行"
if [ -z "$t13_fail" ]; then
    log_has "$cid" "已清理残留 PID 文件 pid.info" \
        || t13_fail="未声明清理 pid.info"
    log_has "$cid" "已清理残留 PID 文件 mixio-backend.pid" \
        || t13_fail="未声明清理 runtime/mixio-backend.pid"
fi
if [ -z "$t13_fail" ]; then
    [ ! -f "$tmp/mixio-app/pid.info" ] \
        || t13_fail="pid.info 未被删除（MixIO 可能按旧 PID 误杀 Xvfb）"
    [ ! -f "$tmp/mixio-app/runtime/mixio-backend.pid" ] \
        || t13_fail="runtime/mixio-backend.pid 未被删除"
fi
if [ -n "$t13_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t13_fail" ] || fail "T13 $t13_fail"
ok "T13 残留 pid.info / mixio-backend.pid 被清理并说明原因"

echo "=== T14 Xvfb 存活监控（误杀的直接证据）==="
# 若清理仍不彻底、Xvfb 真的被误杀，入口脚本必须立即给出结论，
# 而不是让用户面对一片 dbus 噪音。这里验证监控逻辑已就位：
# 启动前端口快照 + Xvfb 监控循环都在日志中可见。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
t14_fail=""
wait_log "$cid" "stub MixlyServer running" 60 || t14_fail="桩二进制未被 exec 执行"
if [ -z "$t14_fail" ]; then
    # 启动前端口快照：判断 18084 是否被占是 daemon_start 误杀的前提
    log_has "$cid" "启动前端口状态" \
        || t14_fail="未输出启动前端口快照（无法判断 18084 是否被占）"
    log_has "$cid" "均空闲" \
        || t14_fail="未确认 8443/18084 等端口空闲"
fi
if [ -n "$t14_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t14_fail" ] || fail "T14 $t14_fail"
ok "T14 启动前端口快照已输出（Xvfb 误杀链的可观测前提）"

echo "=== T15 直连 NW.js 模式（MIXLY_DIRECT_NW=1，绕过官方启动器取 Chromium 内部日志）==="
# 背景：官方 MixlyServer 是 fork+execv 的壳，父进程 stdout 在管道下全缓冲，
# 其 "Checking ports / Starting NW runtime / Loading MixIO service" 进度会随
# 缓冲区丢失，连 "Port conflict detected" 都看不到；还带 "Continue? [y/N]"
# 询问（非 TTY 下读 stdin 立即 EOF）。当进程几秒就退出、日志又一片空白时，
# 启动器这一层只会让可观测性更差。
# MIXLY_DIRECT_NW=1 直接 exec .host/nw 并追加 --enable-logging=stderr，
# 把「窗口句柄为何是 0 / 为何退出」交给 Chromium 自己说。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_DIRECT_NW=1 -v "$tmp:/opt/mixly_server" "$IMAGE")
t15_fail=""
wait_log "$cid" "直连模式" 60 || t15_fail="未进入直连模式"
if [ -z "$t15_fail" ]; then
    log_has "$cid" "跳过官方 MixlyServer 启动器，直接运行 \.host/nw" \
        || t15_fail="未声明跳过官方启动器"
    log_has "$cid" "已追加 --enable-logging=stderr" \
        || t15_fail="未声明追加 Chromium 内部日志开关"
    # 直连模式必须真的把 .host/nw 拉起来。
    # 注意：make_stub 造的 .host/nw 是 gcc -static 的 C 程序，输出 "stub-nw-ok"
    # 并立即退出；打印 "[INFO] stub MixlyServer running" 并常驻的是另一个
    # MixlyServer shell 桩。两者不要搞混（v2.0.9 首轮 CI 就栽在这里）。
    log_has "$cid" "stub-nw-ok" \
        || t15_fail="直连模式未启动 .host/nw"
fi
if [ -z "$t15_fail" ]; then
    # .host/nw 桩会立即退出，容器可能已经停了；docker stop 对已停容器同样返回 0
    docker stop "$cid" >/dev/null 2>&1 || true
    sleep 2
    log_has "$cid" "NW.js 进程已退出，退出码" \
        || t15_fail="未捕获 NW.js 退出码"
fi
if [ -n "$t15_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t15_fail" ] || fail "T15 $t15_fail"
ok "T15 直连模式跳过官方启动器、启动 .host/nw 并打开 Chromium 内部日志"

echo "=== T16 NW.js 最小窗口自检（MIXLY_NW_SELFTEST=1，区分环境问题与应用层问题）==="
# CI 冒烟测试一直用桩替换 MixlyServer，真实 Chromium 从未被验证过，
# 所以「CI 全绿」不等于镜像运行时依赖齐备。自检模式用一个最小 NW 应用
# （临时 package.json + index.html）测本容器能否创建窗口并加载页面：
# 通过 → 依赖齐备，问题在 MixSuite 应用层；失败 → 属镜像依赖问题。
# 桩不知道自检语义，用 MIXLY_STUB_EXIT=0 让它尽快退出，避免等满 timeout。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
cid=$(docker run -d -e MIXLY_NW_SELFTEST=1 -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
t16_fail=""
wait_log "$cid" "自检" 60 || t16_fail="未进入自检模式"
if [ -z "$t16_fail" ]; then
    log_has "$cid" "正在以最小 NW\.js 应用测试窗口创建" \
        || t16_fail="未开始最小窗口自检"
    log_has "$cid" "X 显示: :99" \
        || t16_fail="未报告自检所用的 X 显示"
    # 必须真的把 .host/nw 拉起来（桩输出 stub-nw-ok）
    log_has "$cid" "stub-nw-ok" \
        || t16_fail="自检未运行 .host/nw"
    # 必须给出结论（通过/失败二选一），不能静默
    log_has "$cid" "结论" \
        || t16_fail="自检未给出结论"
fi
if [ -n "$t16_fail" ]; then
    echo "----- 容器日志 -----"
    docker logs "$cid" 2>&1 | tail -25 || true
fi
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t16_fail" ] || fail "T16 $t16_fail"
ok "T16 最小窗口自检模式可用（一次区分镜像依赖问题与 MixSuite 应用层问题）"

echo "=== T17 短命-0 自动取证 + 启动策略轮换（v2.2.0）==="
# 背景：「数秒退出码 0 + 窗口句柄 0」是 NW.js 窗口层故障签名。v2.1.0 实测
# 定位根因：官方启动器传给 .host/nw 的 --ozone-platform=x11 在 Xvfb 下导致
# 窗口创建失败（window 0 → 所有窗口关闭 → 退出码 0，约 3 秒）；不指定 ozone
# 时完全正常。v2.2.0 起把实测可用的「直连无 ozone」提为默认策略 1，官方
# 启动器退居轮换后备：
#   1 直连无 ozone（默认，实测稳定） → 2 官方启动器 → 3 直连强制 ozone → 4 直连关闭遮挡检测
# 入口脚本的行为：
#   * 短命-0 失败时自动执行 auto_forensics（端口探针/日志/错误文件/进程/自检），
#     用户不需要手动 docker exec；
#   * 计数文件 runtime/boot-attempt 在挂载卷内跨重启保留，每次重启自动切换
#     一种启动方式（轮换 1→2→3→4→1）；
#   * 非短命-0 退出（如 docker stop）重置计数，下次仍从默认策略 1 开始。
# 本用例在同一卷上连跑三次验证轮换，再验证 docker stop 后计数重置。
# 注意：其余依赖官方启动器（MixlyServer 桩）的用例统一 -e MIXLY_STRATEGY=2
# 固定策略，不受默认策略变化影响；T15/T16 用 MIXLY_DIRECT_NW/MIXLY_NW_SELFTEST
# 显式模式，同样不参与轮换。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
t17_fail=""

# 第 1 次：短命-0（桩 sleep 2 后 exit 0）→ 策略 1（直连无 ozone）+ 自动取证
cid=$(docker run -d -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
wait_log "$cid" "下次重启自动切换策略 2/4" 90 || t17_fail="第 1 次未走完短命-0 全流程（策略推进/自动取证）"
if [ -z "$t17_fail" ]; then
    log_has "$cid" "启动策略 1/4" || t17_fail="第 1 次未使用默认策略 1（直连无 ozone）"
    log_has "$cid" "直连模式" || t17_fail="策略 1 未进入直连模式"
    # 直连模式必须真的把 .host/nw 拉起来（桩输出 stub-nw-ok）
    log_has "$cid" "stub-nw-ok" || t17_fail="策略 1 未启动 .host/nw"
    log_has "$cid" "自动取证开始" || t17_fail="自动取证缺少起始标记"
    log_has "$cid" "自动取证结束" || t17_fail="自动取证缺少结束标记"
    # 自动取证必须覆盖端口探针与最小窗口自检两项关键证据
    log_has "$cid" "8443 端口探针" || t17_fail="自动取证缺少 8443 端口探针结果"
    log_has "$cid" "NW.js 最小窗口自检" || t17_fail="自动取证缺少 NW.js 最小窗口自检"
fi
docker rm -f "$cid" >/dev/null 2>&1 || true

# 第 2 次：同一卷 → 策略 2（官方启动器 + stdbuf）
if [ -z "$t17_fail" ]; then
    cid=$(docker run -d -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "下次重启自动切换策略 3/4" 90 || t17_fail="第 2 次未切换到策略 2 或未走完全流程（计数器未跨重启保留？）"
    if [ -z "$t17_fail" ]; then
        log_has "$cid" "启动策略 2/4" || t17_fail="第 2 次未使用策略 2"
        log_has "$cid" "官方 MixlyServer" || t17_fail="策略 2 未回到官方启动器路径"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

# 第 3 次：同一卷 → 策略 3（直连，强制 ozone）
if [ -z "$t17_fail" ]; then
    cid=$(docker run -d -e MIXLY_STUB_EXIT=0 -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "下次重启自动切换策略 4/4" 90 || t17_fail="第 3 次未切换到策略 3"
    if [ -z "$t17_fail" ]; then
        log_has "$cid" "启动策略 3/4" || t17_fail="第 3 次未使用策略 3"
        log_has "$cid" "ozone-platform=x11" || t17_fail="策略 3 未追加 ozone 参数"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

# 第 4 次：长命桩 + docker stop → 非短命-0 退出，计数必须重置为 0。
# v2.2.0 起默认策略 1 是直连 .host/nw（桩秒退，活不到 18 秒），所以把计数器
# 预置为 1，让本次走策略 2（官方启动器 + 长命桩）来验证重置与优雅停止。
if [ -z "$t17_fail" ]; then
    mkdir -p "$tmp/mixio-app/runtime"
    echo 1 > "$tmp/mixio-app/runtime/boot-attempt"
    cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "stub MixlyServer running" 60 || t17_fail="第 4 次桩二进制未被 exec 执行"
    if [ -z "$t17_fail" ]; then
        sleep 18
        docker stop -t 10 "$cid" >/dev/null 2>&1 || true
        _att=$(cat "$tmp/mixio-app/runtime/boot-attempt" 2>/dev/null | tr -d '[:space:]' || true)
        [ "$_att" = "0" ] || t17_fail="docker stop 后策略计数未重置（当前值: ${_att:-空}，应为 0）"
        if [ -z "$t17_fail" ]; then
            # 优雅停止不应触发窗口层故障的自动取证（避免误导）
            if log_has "$cid" "自动取证开始"; then
                t17_fail="docker stop 触发了自动取证（停止信号与窗口层故障未区分）"
            fi
        fi
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

if [ -n "$t17_fail" ]; then
    echo "----- 容器日志（末 30 行）-----"
    docker logs "$cid" 2>&1 | tail -30 || true
    echo "----- runtime 目录 -----"
    ls -la "$tmp/mixio-app/runtime" 2>&1 || true
fi
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t17_fail" ] || fail "T17 $t17_fail"
ok "T17 短命-0 自动取证、策略 1→2→3 轮换、stop 后计数重置"

echo "=== T18 MixMO 托管补丁（mixmo 旁路，幂等 patch mixio.js）==="
# 背景：官方 MixSuite 2026-10-15 起包内内置 mixmo/（MixMO · 手机 App 设计），
# 壳菜单/管理端已接入，但服务端 mixio.js 未挂载 /mixmo、首页不传 mixmo 参数。
# 入口脚本 patch_mixmo_support 幂等补齐两处（路由 + 首页传参），锚点链兼容
# 新旧版 mixio.js。本用例锁定：patch 插入、备份、幂等（重启不重复打）、
# 无 mixmo 目录时只告警不阻断。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
t18_fail=""

# 覆盖为含锚点的桩 mixio.js（模拟真实版结构：旁路挂载 + 首页 ejs 传参）
cat > "$tmp/mixio-app/mixio.js" <<'STUB_MIXIO'
var fs = require('fs');
const path = require('path');
var express = require('express');
var app = express();
app.use('/js', express.static(path.join(__dirname, 'js')));
app.use('/mixnt', function (req, res, next) { next(); });
app.get('/', function(req, res) {
    ejs.renderFile(__dirname + '/ejs/index.ejs', {
        'footer': configs["FOOTER"],
        'mixlyHref': mixlyHref || '/mixly',
        'configs': configs
    }, function(err, data) { res.send(data) })
});
STUB_MIXIO
mkdir -p "$tmp/mixmo"
echo '<!doctype html><title>MixMO</title>' > "$tmp/mixmo/index.html"

# 第 1 次：patch 应完整生效（固定策略 2 走官方启动器，与其余用例一致）
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
wait_log "$cid" "stub MixlyServer running" 60 || t18_fail="桩二进制未被 exec 执行（patch 在启动前，应先于本行完成）"
if [ -z "$t18_fail" ]; then
    log_has "$cid" "MixMO 补丁：/mixmo 静态挂载已插入" || t18_fail="未见 /mixmo 路由补丁日志"
    log_has "$cid" "首页 MixMO 入口参数已插入" || t18_fail="未见首页传参补丁日志"
    log_has "$cid" "MixMO 托管补丁完成" || t18_fail="未见补丁完成汇总日志"
    log_has "$cid" "未发现 mixmo/" && t18_fail="有 mixmo/ 却打印了缺失警告"
    # 卷内文件断言：标记、路由、首页传参、备份
    grep -q "MIXLY_DOCKER_MIXMO_PATCH" "$tmp/mixio-app/mixio.js" 2>/dev/null \
        || t18_fail="mixio.js 缺 MIXLY_DOCKER_MIXMO_PATCH 标记"
    grep -q "app.use('/mixmo', function" "$tmp/mixio-app/mixio.js" 2>/dev/null \
        || t18_fail="mixio.js 缺 /mixmo 静态挂载"
    grep -q "'mixmoHref': '/mixmo'," "$tmp/mixio-app/mixio.js" 2>/dev/null \
        || t18_fail="mixio.js 缺首页 mixmoHref 传参"
    [ -f "$tmp/mixio-app/mixio.js.mixly-docker-orig" ] \
        || t18_fail="缺原始 mixio.js 备份（.mixly-docker-orig）"
    grep -q "stub mixio.js\|var app = express" "$tmp/mixio-app/mixio.js.mixly-docker-orig" 2>/dev/null \
        || t18_fail="备份内容不是原始桩"
fi
docker rm -f "$cid" >/dev/null 2>&1 || true

# 第 2 次：同一卷重启 → 幂等（不得重复插入，文件内容不变）
if [ -z "$t18_fail" ]; then
    _md5_before=$(md5sum "$tmp/mixio-app/mixio.js" 2>/dev/null | cut -d' ' -f1)
    cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "stub MixlyServer running" 60 || t18_fail="第 2 次桩未被 exec"
    if [ -z "$t18_fail" ]; then
        if log_has "$cid" "静态挂载已插入"; then
            t18_fail="重启后重复执行了路由补丁（幂等失效）"
        fi
        _md5_after=$(md5sum "$tmp/mixio-app/mixio.js" 2>/dev/null | cut -d' ' -f1)
        [ "$_md5_before" = "$_md5_after" ] || t18_fail="重启后 mixio.js 被改动（幂等失效）"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

# 第 3 次：无 mixmo/ 目录 → 只告警，patch 与启动照常
# （mixio.js 已打过补丁，本次仅验证「缺 mixmo 不阻断、警告照打、路由补丁仍在」）
if [ -z "$t18_fail" ]; then
    rm -rf "$tmp/mixmo"
    cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "stub MixlyServer running" 60 || t18_fail="第 3 次桩未被 exec（缺 mixmo 不应阻断启动）"
    if [ -z "$t18_fail" ]; then
        log_has "$cid" "未发现 mixmo/ 目录" || t18_fail="缺 mixmo/ 时未打印缺失警告"
        # 路由补丁仍应在（运行时 existsSync 自然 404，无副作用）
        grep -q "app.use('/mixmo', function" "$tmp/mixio-app/mixio.js" 2>/dev/null \
            || t18_fail="无 mixmo/ 时 /mixmo 路由补丁缺失（应按存在性动态判定）"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

if [ -n "$t18_fail" ]; then
    echo "----- 容器日志（末 25 行）----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- mixio.js 补丁区 -----"
    grep -n "MIXLY_DOCKER_MIXMO_PATCH" "$tmp/mixio-app/mixio.js" 2>&1 | head -6 || true
fi
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t18_fail" ] || fail "T18 $t18_fail"
ok "T18 MixMO 补丁插入、备份、重启幂等、缺 mixmo 仅告警"

echo "=== T19 /admin 前缀补丁：注入锚点回退（官方改头部写法也不静默失效）==="
# 背景：<base> 与运行时兜底脚本原先只认字面 <meta charset="utf-8">，官方一改这行
# （大写、加属性、换 http-equiv）就整段不注入 —— 页面照常打开、只有在线更新
# /api/download 404，属于最难排查的静默故障。本用例用「没有 meta charset、只有
# <head>/</head>」的模板锁定锚点回退链，并验证重跑幂等。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
mkdir -p "$tmp/mixio-app/ejs"
printf '%s\n' '<html>' '<head>' '<title>admin</title>' '</head>' '<body></body>' '</html>' \
    > "$tmp/mixio-app/ejs/admin.ejs"
printf '%s\n' '<html>' '<head>' '<title>manage</title>' '</head>' \
    '<body><script>var q = "/api/download?url=x";</script></body>' '</html>' \
    > "$tmp/mixio-app/ejs/manage.ejs"
t19_fail=""
cid=$(docker run -d -e MIXLY_STRATEGY=2 -e MIXIO_ADMIN_BASE=/admin \
    -v "$tmp:/opt/mixly_server" "$IMAGE")
wait_log "$cid" "stub MixlyServer running" 60 || t19_fail="桩未被 exec（补丁应先于启动完成）"
if [ -z "$t19_fail" ]; then
    log_has "$cid" "无 <meta charset>，<base> 改注入 </head> 前" \
        || t19_fail="未见 <base> 锚点回退告警"
    log_has "$cid" "已注入 <base href=\"/admin/\">（锚点: head_close）" \
        || t19_fail="<base> 未按 head_close 锚点注入"
    grep -q '<base href="/admin/">' "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null \
        || t19_fail="manage.ejs 缺 <base>"
    # <base> 必须落在 </head> 之前，否则浏览器不采用
    awk '/<base href=/{b=NR} /<\/head>/{h=NR} END{exit !(b && h && b<h)}' \
        "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null \
        || t19_fail="<base> 不在 </head> 之前"
    grep -q "MIXLY_DOCKER_ADMIN_URLFIX" "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null \
        || t19_fail="manage.ejs 运行时兜底未注入"
    grep -q "MIXLY_DOCKER_ADMIN_URLFIX" "$tmp/mixio-app/ejs/admin.ejs" 2>/dev/null \
        || t19_fail="admin.ejs 运行时兜底未注入"
    # Cloudflare RUM 探针（相对路径 cdn-cgi/rum）会被 <base> 改锚成 /admin/cdn-cgi/rum，
    # 兜底脚本必须把它还原成根路径，否则控制台常驻一条 404。
    grep -q "sendBeacon" "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null \
        || t19_fail="运行时兜底未包 sendBeacon（CF RUM 上报会 404）"
    grep -q "cdn-cgi/" "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null \
        || t19_fail="运行时兜底缺 cdn-cgi 还原逻辑"
fi
docker rm -f "$cid" >/dev/null 2>&1 || true

# 重跑：同一卷再启动一次 → 模板一字不变（锚点回退不得产生重复块）
if [ -z "$t19_fail" ]; then
    _md5_before=$(md5sum "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null | cut -d' ' -f1)
    cid=$(docker run -d -e MIXLY_STRATEGY=2 -e MIXIO_ADMIN_BASE=/admin \
        -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "stub MixlyServer running" 60 || t19_fail="第 2 次桩未被 exec"
    if [ -z "$t19_fail" ]; then
        _md5_after=$(md5sum "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null | cut -d' ' -f1)
        [ "$_md5_before" = "$_md5_after" ] || t19_fail="重跑后模板被改动（幂等失效）"
        [ "$(grep -c "MIXLY_DOCKER_ADMIN_URLFIX" "$tmp/mixio-app/ejs/manage.ejs" 2>/dev/null)" = "1" ] \
            || t19_fail="运行时兜底出现重复块"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

if [ -n "$t19_fail" ]; then
    echo "----- 容器日志（末 25 行）----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- manage.ejs 前 10 行 -----"
    head -10 "$tmp/mixio-app/ejs/manage.ejs" 2>&1 || true
fi
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t19_fail" ] || fail "T19 $t19_fail"
ok "T19 <base>/兜底脚本按锚点回退注入，重跑幂等"

echo "=== T20 在线更新写权限（stash 目录 EACCES 回归）==="
# 背景：官方更新流程以 mixly 身份在套件根建 .mixio-app-stash / .mixly-suite-stash、
# 把 mixly/ rename 成备份、就地覆盖 mixio-app/ 内文件。宿主机解压的官方包属主是
# 宿主机用户、目录 755、文件 644，容器内必然 EACCES（实测「正在解压…」后失败：
# EACCES: permission denied, mkdir '/opt/mixly_server/.mixio-app-stash'；
# MixCO 通道没有 stash 步骤，第一个写操作就是 rename，于是同一根因报
# EACCES, Permission denied '/opt/mixly_server/mixco.bak-update'）。
# 入口脚本按需 chmod（不改属主），本用例锁定「mixly 能建 stash、能 rename、
# 能写 mixio-app 内文件」，以及戳文件生效后不再重复递归 chmod。
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
t20_fail=""
cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
wait_log "$cid" "stub MixlyServer running" 60 || t20_fail="桩未被 exec"
if [ -z "$t20_fail" ]; then
    log_has "$cid" "在线更新写权限已就绪" || t20_fail="未见写权限修正日志"
    # 以 mixly 身份复刻官方更新流程的第一批写动作
    docker exec "$cid" gosu mixly:mixly mkdir -p /opt/mixly_server/.mixio-app-stash \
        || t20_fail="mixly 仍无法创建 .mixio-app-stash"
    docker exec "$cid" gosu mixly:mixly mkdir -p /opt/mixly_server/.mixly-suite-stash \
        || t20_fail="mixly 仍无法创建 .mixly-suite-stash"
    docker exec "$cid" gosu mixly:mixly sh -c 'echo x >> /opt/mixly_server/mixio-app/mixio.js' \
        || t20_fail="mixly 仍无法覆盖 mixio-app 内文件"
    # rename 是 promoteStagingDir 的核心动作（mixly/ → mixly.bak-update、
    # mixco/ → mixco.bak-update）。只测 mkdir 会漏掉「能建目录、不能改名」的半通状态。
    docker exec "$cid" gosu mixly:mixly sh -c '
        mkdir /opt/mixly_server/mixco-probe &&
        mv /opt/mixly_server/mixco-probe /opt/mixly_server/mixco-probe.bak-update &&
        rm -rf /opt/mixly_server/mixco-probe.bak-update' \
        || t20_fail="mixly 仍无法在套件根 rename（在线更新 promote 会 EACCES）"
    [ -d "$tmp/.mixio-app-stash" ] || t20_fail="宿主机看不到 stash 目录（写到了别处？）"
fi
docker rm -f "$cid" >/dev/null 2>&1 || true

# 第二次启动：戳文件生效，不应再打印权限修正日志（避免每次启动递归遍历大目录）
if [ -z "$t20_fail" ]; then
    cid=$(docker run -d -e MIXLY_STRATEGY=2 -v "$tmp:/opt/mixly_server" "$IMAGE")
    wait_log "$cid" "stub MixlyServer running" 60 || t20_fail="第 2 次桩未被 exec"
    if [ -z "$t20_fail" ] && log_has "$cid" "修正套件写权限"; then
        t20_fail="戳文件失效：每次启动都重新递归 chmod"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
fi

if [ -n "$t20_fail" ]; then
    echo "----- 容器日志（末 25 行）----"
    docker logs "$cid" 2>&1 | tail -25 || true
    echo "----- 套件根权限 -----"
    ls -ldn "$tmp" "$tmp/mixio-app" 2>&1 || true
fi
rm -rf "$tmp" 2>/dev/null || true
[ -z "$t20_fail" ] || fail "T20 $t20_fail"
ok "T20 套件根对 mixly 可建目录/可改名、mixio-app 可写（更新不再 EACCES），戳文件免重复 chmod"

echo "🎉 冒烟测试全部通过: $PASS/21"

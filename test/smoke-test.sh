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
    # 捕获 TERM/INT 模拟官方应用的优雅退出
    cat > "$dir/MixlyServer" <<'STUB'
#!/bin/sh
echo "[INFO] stub MixlyServer running (foreground)"
trap 'echo "[INFO] stub received stop signal, exiting"; exit 0' TERM INT
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

echo "🎉 冒烟测试全部通过: $PASS/5"

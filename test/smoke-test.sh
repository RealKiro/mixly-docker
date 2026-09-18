#!/usr/bin/env bash
# 入口脚本冒烟测试：无需官方运行包，用假运行包 + ELF 桩二进制
# 校验容器启动链路。用法: smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?用法: smoke-test.sh <image>}"
PASS=0

ok() { echo "✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "❌ $1"; exit 1; }

# 生成 x86_64 静态 ELF 桩（不依赖容器内 glibc/gcompat 环境）
make_stub() { # $1 = 输出路径
    cat > /tmp/mixly-stub.c <<'EOF'
#include <stdio.h>
int main(void) { puts("stub-ok"); return 0; }
EOF
    gcc -static -o "$1" /tmp/mixly-stub.c
}

# 组装假运行包: $1=目录 $2=arm64 时把 e_machine 伪造成 aarch64
make_pkg() {
    local dir="$1" fake="$2"
    mkdir -p "$dir/mixio" "$dir/mixly" "$dir/mixco"
    make_stub "$dir/mixio/mixio"
    if [ "$fake" = "arm64" ]; then
        printf '\xb7\x00' | dd of="$dir/mixio/mixio" bs=1 seek=18 conv=notrunc status=none
    fi
    chmod +x "$dir/mixio/mixio"
}

echo "=== T1 缺包检测 ==="
out=$(docker run --rm "$IMAGE" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "T1 无运行包时应非零退出"
echo "$out" | grep -q "未检测到 Mixly 官方运行包" || fail "T1 未输出放置指引"
ok "T1 缺包时输出放置指引并退出 (exit=$rc)"

echo "=== T2 启动链路（架构匹配的 x64 桩）==="
tmp=$(mktemp -d)
make_pkg "$tmp" x86_64
out=$(docker run --rm -v "$tmp:/opt/mixly_server" "$IMAGE" 2>&1) && rc=0 || rc=$?
echo "$out"
[ "$rc" -eq 0 ] || fail "T2 应零退出"
echo "$out" | grep -q "stub-ok" || fail "T2 桩二进制未被 exec 执行"
echo "$out" | grep -q "运行包架构校验通过" || fail "T2 架构校验未通过"
for d in storage store logs; do
    [ -d "$tmp/mixio/$d" ] || fail "T2 未创建数据目录 $d"
done
uid=$(stat -c '%u' "$tmp/mixio/storage")
[ "$uid" != "0" ] || fail "T2 数据目录仍为 root 属主"
ok "T2 校验/chmod/chown/su-exec 全链路通过（数据目录 uid=$uid）"
rm -rf "$tmp"

echo "=== T3 架构不匹配（x86_64 机器 + arm64 桩）==="
tmp=$(mktemp -d)
make_pkg "$tmp" arm64
out=$(docker run --rm -v "$tmp:/opt/mixly_server" "$IMAGE" 2>&1) && rc=0 || rc=$?
echo "$out"
[ "$rc" -ne 0 ] || fail "T3 架构不匹配时应非零退出"
echo "$out" | grep -q "运行包与机器架构不匹配" || fail "T3 缺少不匹配提示"
ok "T3 下错架构包被明确拦截"
rm -rf "$tmp"

echo "=== T4 镜像元数据 ==="
ep=$(docker inspect -f '{{json .Config.Entrypoint}}' "$IMAGE")
echo "$ep" | grep -q "tini" || fail "T4 Entrypoint 未使用 tini: $ep"
ports=$(docker inspect -f '{{json .Config.ExposedPorts}}' "$IMAGE")
for p in 8080 8443 18084 1883 8082 8083 8084 8086; do
    echo "$ports" | grep -q "\"$p/tcp\"" || fail "T4 缺少端口声明 $p: $ports"
done
ok "T4 Entrypoint(tini) 与 8 个端口声明正确"

echo "=== T5 守护模式（mixio 自我 daemon 化后容器不应停止）==="
tmp=$(mktemp -d)
mkdir -p "$tmp/mixio" "$tmp/mixly"
# 模拟官方 mixio 的真实行为：start 会起后台 debug 子进程后父进程退出，
# debug 才是真正的服务进程（写 pid.info），stop 依据 pid.info 结束它
cat > "$tmp/mixio/mixio" <<'STUB'
#!/bin/sh
case "$1" in
  start)
    ./mixio debug >> "logs/$(date +%H%M%S).log" 2>&1 &
    sleep 1
    echo "[INFO] MixIO server is running now."
    exit 0
    ;;
  debug)
    echo "[INFO] MixIO server is running with PID $$"
    echo $$ > pid.info
    while :; do echo "[INFO] heartbeat $$"; sleep 5; done
    ;;
  stop)
    pid=$(cat pid.info 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    echo "MixIO server with PID $pid is stopped."
    ;;
esac
STUB
chmod -R 777 "$tmp"   # 容器内以非 root(mixly) 运行，需可写 pid.info / logs
cid=$(docker run -d -v "$tmp:/opt/mixly_server" "$IMAGE")
sleep 10
if [ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]; then
    docker logs "$cid" 2>&1 | tail -20
    docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    fail "T5 mixio daemon 化后容器不应停止（容器已退出）"
fi
c_logs=$(docker logs "$cid" 2>&1)
echo "$c_logs" | grep -q "容器进入守护状态" || { docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmp"; fail "T5 未进入守护状态"; }
echo "$c_logs" | grep -q "heartbeat" || { docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmp"; fail "T5 服务日志未跟随到容器输出"; }
docker stop -t 15 "$cid" >/dev/null
docker logs "$cid" 2>&1 | grep -q "收到停止信号" || { docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmp"; fail "T5 停止时未走优雅退服"; }
docker rm -f "$cid" >/dev/null 2>&1 || true
rm -rf "$tmp"
ok "T5 daemon 化后容器保持运行，docker stop 走优雅退服"

echo "🎉 冒烟测试全部通过: $PASS/5"

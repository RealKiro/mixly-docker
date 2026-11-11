#!/usr/bin/env bash
# gen-ip-cert.sh — 为 MixSuite 生成「本地 CA + 含 IP SAN 的服务器证书」
#
# 用途：让浏览器 / App 通过 https://<IP>:8443 直连时，不再出现
#       「连接不是专用连接 / NET::ERR_CERT_AUTHORITY_INVALID」。
#
# 两个必要条件（缺一不可）：
#   1) IP 必须写进证书 SAN（subjectAltName）的 IP 条目。
#      CN 里写 IP，Chrome/Edge/Safari/Firefox 一律不认。
#   2) 客户端必须把生成的 CA 根证书导入「受信任的根证书颁发机构」。
#      只换服务端证书、不装 CA，警告依旧。
#
# 用法：
#   ./gen-ip-cert.sh <套件根目录> [--apply] [--days N] [IP ...] [--dns 域名 ...]
#
# 例：
#   ./gen-ip-cert.sh --apply ./mixly_server 192.168.1.10 \
#       --dns mixly.example.com admin.example.com
#
# 「套件根目录」= docker-compose.yml 里挂到 /opt/mixly_server 的那个目录，
# 下面应有 mixio-app/。IP / 域名可以列多个，全部写进 SAN；
# 127.0.0.1 与 localhost 自动包含；--dns 只是可读性标记，脚本按内容自动分类。
#
# 生成物写到 <套件根>/mixly-certs/：
#   mixio-ca.crt / mixio-ca.key          本地 CA（ca.key 勿分发、勿上传）
#   mixio-server.crt / mixio-server.key  服务端证书与私钥
#
# 默认只生成文件；加 --apply 会就地覆盖官方 mixio-app/config/certs/ 里
# 现有的证书/私钥（保持原文件名，无需改 config.json），原文件备份为
# *.mixly-orig（已存在则不覆盖备份）。
#
# 续期：直接重跑同一条命令。已存在的 CA 会被复用，客户端无需重新导入。
#
# 依赖：openssl >= 1.1.1（Windows Git Bash / Linux / 群晖 SSH 均可）。
#
set -eu

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

APPLY=0
DAYS="${DAYS:-365}"

if [ "$#" -lt 1 ]; then
    usage 1
fi

ROOT="$1"
shift

SAN_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=1 ;;
        --days)    shift; DAYS="$1" ;;
        DAYS=*)    DAYS="${1#DAYS=}" ;;
        --dns)     ;;                     # 可读性标记，按内容自动分类
        -h|--help) usage 0 ;;
        *)         SAN_ARGS+=("$1") ;;
    esac
    shift
done

APP="$ROOT/mixio-app"
if [ ! -d "$APP" ]; then
    echo "[错误] 未找到 $APP" >&2
    echo "       第一个参数应是官方运行包解压后的套件根目录（内含 mixio-app/）。" >&2
    exit 1
fi
CERTS="$APP/config/certs"
OUT="$ROOT/mixly-certs"

command -v openssl >/dev/null 2>&1 || { echo "[错误] 找不到 openssl" >&2; exit 1; }

# ---------------------------------------------------------------- SAN 收集
IPS="127.0.0.1"
DNSS="localhost"

add_ip()  { case " $IPS "  in *" $1 "*) ;; *) IPS="$IPS $1" ;;  esac; }
add_dns() { case " $DNSS " in *" $1 "*) ;; *) DNSS="$DNSS $1" ;; esac; }

for a in ${SAN_ARGS[@]+"${SAN_ARGS[@]}"}; do
    if printf '%s' "$a" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        add_ip "$a"
    else
        add_dns "$a"
    fi
done

CN=$(printf '%s\n' "$IPS" | awk '{print $2}')
[ -n "$CN" ] || CN="127.0.0.1"

mkdir -p "$OUT"
# 工作目录放在输出目录内：Windows Git Bash 下 mktemp -d 会返回带盘符的路径，
# rm -rf 清理时既容易被安全策略拦截，也会让 EXIT trap 把退出码改成非 0。
WORK="$OUT/.work"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT INT TERM

# ------------------------------------------------------------------ 本地 CA
if [ -s "$OUT/mixio-ca.crt" ] && [ -s "$OUT/mixio-ca.key" ]; then
    echo "[1/3] 复用已有 CA：$OUT/mixio-ca.crt（客户端无需重新导入）"
else
    echo "[1/3] 生成根 CA（有效期 3650 天）..."
    cat > "$WORK/ca.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[ dn ]
CN = Mixly Local CA
[ v3_ca ]
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$OUT/mixio-ca.key" -out "$OUT/mixio-ca.crt" \
        -config "$WORK/ca.cnf" 2>/dev/null
fi

# ------------------------------------------------------- 服务端证书（含 IP SAN）
echo "[2/3] 签发服务端证书（有效期 ${DAYS} 天）"
{
    printf '[ req ]\n'
    printf 'distinguished_name = dn\n'
    printf 'req_extensions     = v3_req\n'
    printf 'prompt             = no\n\n'
    printf '[ dn ]\nCN = %s\n\n' "$CN"
    printf '[ v3_req ]\n'
    printf 'basicConstraints       = critical,CA:FALSE\n'
    printf 'keyUsage               = critical,digitalSignature,keyEncipherment\n'
    printf 'extendedKeyUsage       = serverAuth\n'
    printf 'subjectAltName         = @alt_names\n\n'
    printf '[ alt_names ]\n'
    _i=0; for _ip in $IPS;  do _i=$((_i+1)); printf 'IP.%d  = %s\n'  "$_i" "$_ip";  done
    _i=0; for _dn in $DNSS; do _i=$((_i+1)); printf 'DNS.%d = %s\n' "$_i" "$_dn"; done
} > "$WORK/server.cnf"

openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$WORK/server.key" -out "$WORK/server.csr" \
    -config "$WORK/server.cnf" 2>/dev/null

openssl x509 -req -in "$WORK/server.csr" \
    -CA "$OUT/mixio-ca.crt" -CAkey "$OUT/mixio-ca.key" -CAcreateserial \
    -out "$OUT/mixio-server.crt" -days "$DAYS" -sha256 \
    -extfile "$WORK/server.cnf" -extensions v3_req 2>/dev/null

cp "$WORK/server.key" "$OUT/mixio-server.key"
chmod 600 "$OUT/mixio-ca.key" "$OUT/mixio-server.key" 2>/dev/null || true

openssl verify -CAfile "$OUT/mixio-ca.crt" "$OUT/mixio-server.crt" >/dev/null
echo "      SAN: $(openssl x509 -in "$OUT/mixio-server.crt" -noout -ext subjectAltName | tail -n 1 | sed 's/^ *//')"

# ------------------------------------------------------------- 就地替换官方证书
if [ "$APPLY" = "1" ]; then
    echo "[3/3] 覆盖官方 certs/ 里的证书与私钥（保持原文件名）"
    if [ ! -d "$CERTS" ]; then
        echo "[错误] 目录不存在：$CERTS" >&2
        exit 1
    fi
    _n=0
    for f in "$CERTS"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.mixly-orig) continue ;; esac
        _crt=0; _key=0
        if grep -q -- "BEGIN CERTIFICATE" "$f"; then _crt=1; fi
        if grep -q -- "PRIVATE KEY"       "$f"; then _key=1; fi
        [ "$_crt" = 1 ] || [ "$_key" = 1 ] || continue

        [ -f "$f.mixly-orig" ] || cp -p "$f" "$f.mixly-orig"
        if   [ "$_crt" = 1 ] && [ "$_key" = 1 ]; then
            cat "$OUT/mixio-server.crt" "$OUT/mixio-server.key" > "$f"   # 合并 PEM
        elif [ "$_crt" = 1 ]; then
            cp "$OUT/mixio-server.crt" "$f"
        else
            cp "$OUT/mixio-server.key" "$f"
        fi
        echo "      ✓ $f"
        _n=$((_n+1))
    done
    if [ "$_n" -eq 0 ]; then
        echo "[警告] 没在 $CERTS 找到证书/私钥文件。" >&2
        echo "       请查看 config.json 的 HTTPS_CRT_FILE / HTTPS_PRIVATE_PEM，" >&2
        echo "       手动把 mixio-server.crt / .key 拷贝过去。" >&2
    fi
else
    echo "[3/3] 未加 --apply，仅生成文件。手动把 mixio-server.crt / .key"
    echo "       覆盖到 $CERTS 下 config.json 指向的那两个文件即可。"
fi

cat <<EOF

生成目录：$OUT
  mixio-ca.crt        ← 导入每台客户端的「受信任的根证书颁发机构」
  mixio-ca.key        ← CA 私钥，务必保管好，不要分发
  mixio-server.crt / mixio-server.key

下一步：
  1) 把 mixio-ca.crt 导入各客户端（Windows/macOS/手机）；Chrome/Edge 用系统证书库，
     Firefox 需单独导入；导入后重启浏览器。
  2) docker restart mixly-server
  3) 浏览器打开 https://$CN:8443 应直接显示小锁，无警告。
  4) 官方在线更新可能覆盖 certs/，更新后若又告警，重跑本脚本并重启容器。
EOF

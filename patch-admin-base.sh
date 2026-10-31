#!/bin/sh
# ============================================================================
# patch-admin-base.sh — MixIO 管理后台「/admin 路径」反代补丁（裸机版）
#
# 背景：18084 管理后台是独立的 express 应用，全部路由（/ 登录页、/admin 面板、
# /adminLogin、/js/… 静态资源）都按根路径注册；首页“管理后台”链接也固定拼成
# https://<当前主机>:18084。用反向代理把它挂到同一域名的 /admin 路径时：
#   * 反代通常只转发 /admin*，管理端收到的路径带前缀，官方路由匹配不上；
#   * 首页链接仍然跳 https://域名:18084（Cloudflare 等不代理非标准端口，直接打不开）。
#
# 本脚本对官方运行包做三处幂等修改（不动你的数据，只改程序文件）：
#   1) mixio.js：管理端路由前插入前缀剥离中间件（/admin/→/、/admin/admin→/admin、
#      /admin/js/…→/js/…），未登录时的 res.redirect('/') 改为跳 <BASE>/（登录页）；
#   2) ejs/admin.ejs、ejs/manage.ejs：注入 <base href="<BASE>/">，并把少数以 /
#      开头的 URL 改成相对路径（adminLogin、saveAndRestart、stop、start、
#      api/check-update、api/exit-after-update、api/download（在线更新 SSE 进度）、
#      ?page= 导航等）；
#   3) js/login.js（含 Mixly 编辑器内嵌页副本 mixly/mixvm/mixio/js/login.js）：
#      首页“管理后台”链接在标准端口（443/无端口）下指向 <BASE>，非标准端口
#      仍指向 :18084（本地直连 8443 时不退化）。
#
# 幂等：所有插入块带 MIXLY_DOCKER_ADMIN_BASE_PATCH 标记，重复执行结果一致；
# 官方在线更新覆盖相关文件后（标记丢失）重跑一次即可重新生效。
# 首次执行前自动备份原件为 <文件>.mixly-docker-orig（已备份过则不覆盖）。
#
# 用法：
#   ./patch-admin-base.sh <MixSuite套件根目录> [admin前缀，默认 /admin]
# 示例：
#   ./patch-admin-base.sh /volume1/docker/mixly/mixly_server /admin
#   ./patch-admin-base.sh ./MixSuite-linux-x64            # 前缀取默认 /admin
#
# 反代侧要求：把 /admin(/.*)? 原样转发到 18084（不要剥前缀），例如 Nginx：
#   location /admin {
#       proxy_pass https://127.0.0.1:18084;   # 注意不带尾斜杠
#       proxy_ssl_verify off;                  # 18084 自签证书
#       proxy_set_header Host $host;
#       proxy_set_header X-Forwarded-Proto $scheme;
#   }
# ============================================================================
set -e

SUITE_DIR="${1:-}"
BASE="${2-/admin}"
LINK_URL="${3:-${MIXIO_ADMIN_URL:-}}"

log()  { echo "[patch-admin-base] $*"; }
warn()  { echo "[patch-admin-base][WARN] $*" >&2; }

if [ -z "$SUITE_DIR" ]; then
    echo "用法: $0 <MixSuite套件根目录> [admin前缀，默认 /admin] [管理端完整地址，可选]" >&2
    echo "  路径模式: $0 /opt/mixly_server /admin" >&2
    echo "  子域名模式: $0 /opt/mixly_server '' https://admin.example.com/" >&2
    exit 1
fi
BASE="${BASE%/}"
if [ -z "$BASE" ] && [ -z "$LINK_URL" ]; then
    warn "第二个参数为空且未提供管理端地址（第三个参数 / MIXIO_ADMIN_URL）；如需路径模式请传 /admin"
    exit 1
fi
if [ -n "$BASE" ]; then
    case "$BASE" in
        /*) ;;
        *) warn "前缀必须以 / 开头（当前: $BASE），已忽略"; exit 1 ;;
    esac
    if ! printf '%s' "$BASE" | grep -Eq '^/[A-Za-z0-9._~/-]*$'; then
        warn "前缀含非法字符（仅允许字母数字和 . _ ~ / -），已忽略"
        exit 1
    fi
fi

APP_DIR="$SUITE_DIR/mixio-app"
RT="$APP_DIR/runtime"
mkdir -p "$RT" 2>/dev/null || true

# 备份（首次 patch 前；已备份过则保留更早的原始版本）
backup_once() {
    _f="$1"
    [ -f "$_f" ] || return 0
    if [ ! -f "$_f.mixly-docker-orig" ]; then
        cp "$_f" "$_f.mixly-docker-orig" 2>/dev/null \
            && log "已备份 $(basename "$_f") → $(basename "$_f").mixly-docker-orig" \
            || warn "备份 $_f 失败（不影响补丁本身）"
    fi
}

# ------------------------------------- 管理端入口链接（子域名模式 / 显式指定地址）
# 首页“管理后台”按钮的地址有两种来源：路径模式下按端口判断走 <BASE>，
# 子域名模式下必须显式给完整地址（LINK_URL）。两者同时存在时以 LINK_URL 为准。
rewrite_admin_link() {
    [ -n "$LINK_URL" ] || return 0
    case "$LINK_URL" in
        http://*|https://*|/*) ;;
        *) warn "管理端地址需以 http://、https:// 或 / 开头（当前: $LINK_URL），已忽略"; return 0 ;;
    esac
    for _lf in "$APP_DIR/js/login.js" "$SUITE_DIR/mixly/mixvm/mixio/js/login.js"; do
        [ -f "$_lf" ] || continue
        backup_once "$_lf"
        if grep -qF "$LINK_URL" "$_lf" 2>/dev/null; then
            log "$(basename "$_lf") 已指向 $LINK_URL，跳过"
            continue
        fi
        awk -v url="$LINK_URL" '
            index($0, ":18084") && index($0, "href:") {
                print "        href: (window.MIXIO_ADMIN_URL || \"" url "\"),"
                next
            }
            index($0, ":18084") && index($0, "attr(\"href\"") {
                print "        $(\"#admin\").attr(\"href\", window.MIXIO_ADMIN_URL || \"" url "\")"
                next
            }
            { print }
        ' "$_lf" > "$RT/login-url.patched" 2>/dev/null &&
        cat "$RT/login-url.patched" > "$_lf" 2>/dev/null &&
        log "$(basename "$_lf")：首页“管理后台” → $LINK_URL" ||
            warn "改写 $(basename "$_lf") 失败"
        rm -f "$RT/login-url.patched" 2>/dev/null || true
    done
}

# 子域名模式（BASE 为空）：管理端在自己的根路径下工作，不需要剥离前缀、
# 不需要 <base>，只改首页入口。适用于 Cloudflare 面板隧道 / DSM 反向代理
# 这类无法按路径分流的入口。
if [ -z "$BASE" ]; then
    rewrite_admin_link
    log "完成：子域名模式（管理端 $LINK_URL，无前缀改写）。请重启 MixIO 服务。"
    exit 0
fi

# ---------------------------------------------------------------- 1) mixio.js
# 前缀剥离中间件 + 未登录重定向到 <BASE>/
MJ="$APP_DIR/mixio.js"
if [ ! -f "$MJ" ]; then
    warn "未找到 $MJ，跳过 mixio.js 补丁（官方运行包不完整？）"
else
    backup_once "$MJ"
    if grep -q "MIXLY_DOCKER_ADMIN_BASE_PATCH" "$MJ" 2>/dev/null; then
        log "mixio.js 已打过（标记存在），跳过"
    else
        _ln_admin=$(grep -n "ejs/admin.ejs" "$MJ" | head -1 | cut -d: -f1)
        _ln_route=$(( ${_ln_admin:-0} - 1 ))
        _ln_redirect=$(grep -n "res.redirect('/')" "$MJ" | head -1 | cut -d: -f1)
        _ok=1
        [ -n "$_ln_admin" ] && [ "$_ln_route" -gt 0 ] || _ok=0
        [ "$_ok" = "1" ] && [ -n "$_ln_redirect" ] && [ "$_ln_redirect" -gt "$_ln_route" ] || _ok=0
        [ "$_ok" = "1" ] && sed -n "${_ln_route}p" "$MJ" | grep -qF "app.get('/', function" || _ok=0
        [ "$_ok" = "1" ] && sed -n "${_ln_route},${_ln_redirect}p" "$MJ" | grep -qF "app.get('/admin'" || _ok=0

        if [ "$_ok" != "1" ]; then
            warn "未能在 mixio.js 中定位管理端路由锚点（版本差异？），已跳过 mixio.js 补丁"
        else
            cat > "$RT/admin-base-route.patch.js" <<PATCH_EOF

// [MIXLY_DOCKER_ADMIN_BASE_PATCH] 反向代理前缀支持（BASE=${BASE}）
// 官方管理端路由全部按根路径注册；反代把 18084 挂到 ${BASE} 时，这里在
// 路由之前剥掉前缀：${BASE}/→/、${BASE}/admin→/admin、${BASE}/js/…→/js/…。
var __mixlyAdminBase = '${BASE}';
if (__mixlyAdminBase) {
    app.use(function (req, res, next) {
        var __u = req.url || '/';
        if (__u === __mixlyAdminBase) {
            req.url = '/admin';
        } else if (__u.indexOf(__mixlyAdminBase + '/') === 0) {
            req.url = __u.slice(__mixlyAdminBase.length);
        } else if (__u.indexOf(__mixlyAdminBase + '?') === 0) {
            req.url = '/admin' + __u.slice(__mixlyAdminBase.length);
        }
        next();
    });
}
PATCH_EOF
            printf "            res.redirect(__mixlyAdminBase + '/')\n" > "$RT/admin-base-redirect.patch.js"

            awk -v route="$_ln_route" -v redirect="$_ln_redirect" \
                -v mw="$RT/admin-base-route.patch.js" -v rw="$RT/admin-base-redirect.patch.js" '
                NR == route {
                    while ((getline _l < mw) > 0) print _l
                    close(mw)
                }
                NR == redirect {
                    while ((getline _l < rw) > 0) print _l
                    close(rw)
                    next
                }
                { print }
            ' "$MJ" > "$RT/mixio.js.patched" 2>/dev/null

            if [ -s "$RT/mixio.js.patched" ]; then
                cat "$RT/mixio.js.patched" > "$MJ" 2>/dev/null \
                    && log "mixio.js 已支持 ${BASE}（剥离前缀；未登录跳 ${BASE}/）" \
                    || warn "写入 mixio.js 失败（不可写？）"
            else
                warn "生成 patched 文件失败，已跳过 mixio.js 补丁"
            fi
            rm -f "$RT/mixio.js.patched" 2>/dev/null || true
        fi
    fi
fi

# --------------------------------------------- 2) 管理端模板：<base> + 相对路径
# <base href="<BASE>/"> 让模板里的相对路径（js/…、adminLogin、saveAndRestart 等）
# 一律以 <BASE>/ 为基准解析，页面停在 /admin（无尾斜杠）时也不会落到站点根。
TPL="$APP_DIR/ejs"
BASE_TAG="    <base href=\"${BASE}/\">"
MK="    <!-- [MIXLY_DOCKER_ADMIN_BASE_PATCH] 反向代理前缀（MIXIO_ADMIN_BASE=${BASE}）：相对路径以该前缀为基准 -->"
for _f in "$TPL/admin.ejs" "$TPL/manage.ejs"; do
    [ -f "$_f" ] || continue
    backup_once "$_f"
    if grep -q "MIXLY_DOCKER_ADMIN_BASE_PATCH" "$_f" 2>/dev/null; then
        # 已注入过：只更新 base 的取值（换前缀时无需还原原件）
        awk -v tag="$BASE_TAG" '
            /<base href=/ { print tag; next }
            { print }
        ' "$_f" > "$RT/ejs.patched" 2>/dev/null &&
        cat "$RT/ejs.patched" > "$_f" 2>/dev/null ||
            warn "更新 $(basename "$_f") 的 <base> 失败"
    else
        # 锚点链（防官方改版后静默失效）：<meta charset=…>（大小写/属性不限）
        # → </head> 前 → <head…> 后。旧实现只认字面 <meta charset="utf-8">，
        # 官方一改这行（大写、加属性、换 http-equiv）就整段不注入；此时页面
        # 照常能打开、只有在线更新 404，是最难排查的静默故障。
        ANCH=""
        if grep -qiE '<meta[^>]*charset' "$_f" 2>/dev/null; then
            ANCH=meta
        elif grep -qi '</head' "$_f" 2>/dev/null; then
            ANCH=head_close
            warn "$(basename "$_f") 无 <meta charset>，<base> 改注入 </head> 前"
        elif grep -qi '<head[[:space:]>]' "$_f" 2>/dev/null; then
            ANCH=head_open
            warn "$(basename "$_f") 无 <meta charset>/</head>，<base> 改注入 <head> 后"
        else
            warn "$(basename "$_f") 找不到 meta/head 锚点，跳过 <base>（运行时兜底仍会尝试）"
        fi
        if [ -n "$ANCH" ]; then
            awk -v tag="$BASE_TAG" -v mk="$MK" -v mode="$ANCH" '
                mode == "meta" && !ins && tolower($0) ~ /<meta[^>]*charset/ {
                    print; print mk; print tag; ins = 1; next
                }
                mode == "head_close" && !ins && tolower($0) ~ /<\/head/ {
                    print mk; print tag; ins = 1
                }
                mode == "head_open" && !ins && tolower($0) ~ /<head[[:space:]>]/ {
                    print; print mk; print tag; ins = 1; next
                }
                { print }
            ' "$_f" > "$RT/ejs.patched" 2>/dev/null &&
            cat "$RT/ejs.patched" > "$_f" 2>/dev/null &&
            log "$(basename "$_f") 已注入 <base href=\"${BASE}/\">（锚点: ${ANCH}）" ||
                warn "注入 $(basename "$_f") 的 <base> 失败"
        fi
    fi
    rm -f "$RT/ejs.patched" 2>/dev/null || true
done

# ---------------------------------------- 2b) 运行时兜底：根路径请求补前缀
# sed 只能命中已知写法；官方不同版本写法会变（反引号 / 单引号 / 双引号、字符串
# 拼接），漏一条就是 404。这里往页面注入一段极小的脚本，统一改写
# fetch / XHR / EventSource 的根路径 URL —— 不依赖模板写法，也不怕新增接口。
#
# 注入锚点同样有回退链：<base href=…> 之后（默认）→ </head> 前 → <head…> 后
# → 文件末尾。这段脚本是「最后一道保险」，它没进去就等于在线更新必然 404，
# 所以宁可追加到末尾也要注入，并逐个文件回读校验标记是否真的落盘。
SNIP="$RT/admin-urlfix.snippet"
{
    printf '    <script>/* [MIXLY_DOCKER_ADMIN_URLFIX] 根路径请求补前缀（BASE=%s） */\n' "$BASE"
    printf '    (function(){var b="%s";function fix(u){if(typeof u!=="string"||u.charAt(0)!=="/"||u.charAt(1)==="/")return u;if(u===b||u.indexOf(b+"/")===0)return u;return b+u;}var of=window.fetch;if(of){window.fetch=function(u){var a=[].slice.call(arguments);a[0]=fix(u);return of.apply(this,a);};}var xo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){var a=[].slice.call(arguments);a[1]=fix(u);return xo.apply(this,a);};var OE=window.EventSource;if(OE){var NE=function(u,c){return new OE(fix(u),c);};NE.prototype=OE.prototype;window.EventSource=NE;};})();\n' "$BASE"
    printf '    </script>\n'
} > "$SNIP" 2>/dev/null
for _f in "$TPL/admin.ejs" "$TPL/manage.ejs"; do
    [ -f "$_f" ] || continue
    [ -s "$SNIP" ] || { warn "运行时兜底片段为空，跳过 $(basename "$_f")"; break; }
    SMODE=tail
    if grep -qiE '<base[[:space:]]+href=' "$_f" 2>/dev/null; then
        SMODE=base
    elif grep -qi '</head' "$_f" 2>/dev/null; then
        SMODE=head_close
        warn "$(basename "$_f") 无 <base>，运行时兜底改注入 </head> 前"
    elif grep -qi '<head[[:space:]>]' "$_f" 2>/dev/null; then
        SMODE=head_open
        warn "$(basename "$_f") 无 <base>/</head>，运行时兜底改注入 <head> 后"
    else
        warn "$(basename "$_f") 无 <base>/</head>/<head>，运行时兜底追加到文件末尾"
    fi
    awk -v snip="$SNIP" -v mode="$SMODE" '
        /MIXLY_DOCKER_ADMIN_URLFIX/ { drop = 1; next }
        drop && /<\/script>/ { drop = 0; next }
        drop { next }
        mode == "base" && !ins && tolower($0) ~ /<base[[:space:]]+href=/ {
            print
            while ((getline _l < snip) > 0) print _l
            close(snip); ins = 1; next
        }
        mode == "head_close" && !ins && tolower($0) ~ /<\/head/ {
            while ((getline _l < snip) > 0) print _l
            close(snip); ins = 1
        }
        mode == "head_open" && !ins && tolower($0) ~ /<head[[:space:]>]/ {
            print
            while ((getline _l < snip) > 0) print _l
            close(snip); ins = 1; next
        }
        { print }
        END {
            if (mode == "tail" && !ins) {
                while ((getline _l < snip) > 0) print _l
            }
        }
    ' "$_f" > "$RT/ejs.patched" 2>/dev/null &&
    cat "$RT/ejs.patched" > "$_f" 2>/dev/null
    # 回读校验：标记必须真的落在文件里，否则告警（静默失败 = 在线更新必然 404）
    if grep -q "MIXLY_DOCKER_ADMIN_URLFIX" "$_f" 2>/dev/null; then
        log "$(basename "$_f") 已注入运行时 URL 兜底（fetch/XHR/EventSource，锚点: ${SMODE}）"
    else
        warn "注入 $(basename "$_f") 的运行时兜底失败（页面将回落到逐条 sed，可能仍 404）"
    fi
    rm -f "$RT/ejs.patched" 2>/dev/null || true
done
rm -f "$SNIP" 2>/dev/null || true

if [ -f "$TPL/admin.ejs" ]; then
    sed -e "s|\$.post('/adminLogin'|\$.post('adminLogin'|g" \
        "$TPL/admin.ejs" > "$RT/admin.ejs.patched" 2>/dev/null &&
    cat "$RT/admin.ejs.patched" > "$TPL/admin.ejs" 2>/dev/null ||
        warn "改写 ejs/admin.ejs 失败"
    rm -f "$RT/admin.ejs.patched" 2>/dev/null || true
fi
if [ -f "$TPL/manage.ejs" ]; then
    sed -e 's|href="/admin?page=|href="admin?page=|g' \
        -e "s|url: '/saveAndRestart'|url: 'saveAndRestart'|" \
        -e "s|\$.get('/stop'|\$.get('stop'|" \
        -e "s|\$.get('/start'|\$.get('start'|" \
        -e "s|fetch('/api/check-update'|fetch('api/check-update'|" \
        -e "s|fetch('/api/exit-after-update'|fetch('api/exit-after-update'|" \
        -e "s|fetch('/stop'|fetch('stop'|" \
        -e 's|EventSource(`/api/download|EventSource(`api/download|' \
        -e 's|EventSource("/api/download|EventSource("api/download|' \
        -e "s|EventSource('/api/download|EventSource('api/download|" \
        -e "s|'/api/download|'api/download|g" \
        -e 's|href="index"|href="admin"|' \
        "$TPL/manage.ejs" > "$RT/manage.ejs.patched" 2>/dev/null &&
    cat "$RT/manage.ejs.patched" > "$TPL/manage.ejs" 2>/dev/null ||
        warn "改写 ejs/manage.ejs 失败"
    rm -f "$RT/manage.ejs.patched" 2>/dev/null || true
fi

# ------------------------------------- 3) 首页“管理后台”链接（js/login.js）
# 标准端口（443/无端口）指向 <BASE>，非标准端口保留 :18084
LJ="$APP_DIR/js/login.js"
if [ -f "$LJ" ] && grep -q ":18084" "$LJ" 2>/dev/null; then
    backup_once "$LJ"
    awk -v base="$BASE" '
        index($0, ":18084") && index($0, "href:") {
            print "        href: (window.MIXIO_ADMIN_URL || ((window.location.port === \"\" || window.location.port === \"443\") ? \"" base "\" : \"https://\" + window.location.hostname + \":18084\")),"
            next
        }
        { print }
    ' "$LJ" > "$RT/login.js.patched" 2>/dev/null &&
    cat "$RT/login.js.patched" > "$LJ" 2>/dev/null &&
    log "首页“管理后台”链接已适配（443 → ${BASE}，其它端口保留 :18084）" ||
        warn "改写 js/login.js 失败"
    rm -f "$RT/login.js.patched" 2>/dev/null || true
fi

# Mixly 编辑器内嵌的 mixio 登录页有同一逻辑的副本（pure-web 版），一并适配
LJ2="$SUITE_DIR/mixly/mixvm/mixio/js/login.js"
if [ -f "$LJ2" ] && grep -q ":18084" "$LJ2" 2>/dev/null; then
    backup_once "$LJ2"
    awk -v base="$BASE" '
        index($0, ":18084") && index($0, "attr(\"href\"") {
            print "        $(\"#admin\").attr(\"href\", window.MIXIO_ADMIN_URL || ((window.location.port === \"\" || window.location.port === \"443\") ? \"" base "\" : \"https://\" + window.location.hostname + \":18084\"))"
            next
        }
        { print }
    ' "$LJ2" > "$RT/login2.js.patched" 2>/dev/null &&
    cat "$RT/login2.js.patched" > "$LJ2" 2>/dev/null &&
    log "pure-web 副本（mixly/mixvm/mixio/js/login.js）已同步适配" ||
        warn "改写 pure-web login.js 失败"
    rm -f "$RT/login2.js.patched" 2>/dev/null || true
fi

rm -f "$RT/admin-base-route.patch.js" "$RT/admin-base-redirect.patch.js" 2>/dev/null || true

# 若显式给了管理端地址，覆盖上面按端口推导出的入口（放在最后，优先级最高）
rewrite_admin_link

# 汇总验证
_n=0
for _f in "$MJ" "$TPL/admin.ejs" "$TPL/manage.ejs" "$LJ2"; do
    [ -f "$_f" ] || continue
    _c=$(grep -c "MIXLY_DOCKER_ADMIN_BASE_PATCH" "$_f" 2>/dev/null) || _c=0
    [ -n "$_c" ] || _c=0
    _n=$((_n + _c))
done
if [ "$_n" -ge 3 ]; then
    log "完成：管理后台将以 ${BASE} 提供（登录页 ${BASE}/，面板 ${BASE}/admin）。"
    log "请重启 MixIO 服务使补丁生效；反参见脚本头部说明（原样转发、勿剥前缀）。"
else
    warn "补丁未完整生效（标记数: ${_n}，期望 ≥3）；请检查上方 WARN 输出"
    exit 1
fi

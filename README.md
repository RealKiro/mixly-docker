# mixly-docker

[![docker-ci](https://github.com/RealKiro/mixly-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/RealKiro/mixly-docker/actions/workflows/ci.yml)

适配 [Mixly 米思齐](https://mixly.cn) **Mixly 4.0（MixSuite）** 离线服务端的 Docker 运行环境，支持群晖 NAS 等 **x64 / arm64 / loong64** 设备。

**镜像只含运行环境（约 300MB，Debian + NW.js/X11 依赖 + Xvfb 虚拟显示），不含官方运行包。** 需自行从官方百度网盘下载对应架构的 `MixSuite-linux-<架构>.zip`，解压后放进映射目录。

> Mixly 4.0 起官方只有一个发行版：内置 MixIO 的 **MixSuite**（NW.js 应用），替代旧版 `mixly_server`（`mixio` 单文件）。**强制 HTTPS**：HTTP(8080) 被官方固定关闭，请用 `https://NAS_IP:8443`。从 v1.x 升级见[迁移说明](#从-v1xmixly_server-迁移)。
>
> 实现原理、构建与深度排障见 [README-docker.md](README-docker.md)。

---

## 快速开始

### 1. 构建自己的镜像（推荐）

本项目不提供公共镜像。Fork 后用自己的 GitHub Actions 构建，拉取快、版本可控、不依赖他人仓库：

1. **Star + Fork** 本仓库。
2. 进入你 Fork 的仓库 → **Actions** → 按提示点 **I understand my workflows, go ahead and enable them** → 左侧选 **docker-ci** → **Run workflow**。
   （也可以推 tag 触发：`git tag v2.0 && git push origin v2.0`）
3. 几分钟完成（含 QEMU 构建 arm64/loong64），产出多架构镜像：

   ```
   ghcr.io/<你的GitHub用户名>/mixly-server:latest   # amd64 + arm64 + loong64
   ```

   使用 Actions 自带 `GITHUB_TOKEN`，**无需配置任何 Secrets**。（可选推 Docker Hub：配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，未配自动跳过。）
4. 头像 → **Packages** → `mixly-server` → **Package settings** → **Change visibility** → **Public**。
   （保持 Private 也行，但 NAS 端要先 `docker login ghcr.io`。）

### 2. 放置官方运行包

按机器架构下载（x64 / arm64 / loong64，不清楚可咨询主机厂家），把**压缩包里的全部内容**放进映射目录（示例 `/docker/mixly/mixly_server`）。放好后应存在：

```
/docker/mixly/mixly_server/MixlyServer           # 启动器
/docker/mixly/mixly_server/.host/nw             # NW.js 运行时
/docker/mixly/mixly_server/mixio-app/mixio.js   # MixIO 服务端
/docker/mixly/mixly_server/mixly/               # Mixly 编辑器
```

⚠️ 多套一层 `MixSuite-linux-x64/` 是最常见的错误——要放**文件夹里面的内容**。入口脚本对多套一层有自动兼容，但仍建议放对。

### 3. 启动

下载 [docker-compose.yml](docker-compose.yml) 到 `/docker/mixly/`，把 `image:` 改成你自己的镜像后启动：

```bash
docker compose up -d
# 群晖：Container Manager → 项目 → 新增 → 选择该 compose 文件 → 启动
```

> **内存与共享内存**：NW.js 是完整 Chromium，`/dev/shm` 默认只有 64MB，不足会让渲染进程静默退出（容器每隔一两分钟自己重启、日志里看不到原因）。compose 已内置 `shm_size: '1gb'`；用 `docker run` 必须加 `--shm-size=1g`，并给容器留 1.5GB 以上内存。

### 4. 访问

| 入口 | 地址 | 说明 |
|---|---|---|
| MixIO / Mixly 主界面 | `https://NAS_IP:8443` | 强制 HTTPS；自签证书提示"连接不是专用连接"时点**高级 → 继续访问** |
| 管理模式 | `https://NAS_IP:18084` | 数据管理、用户导入、在线更新；也可经反代走 `https://域名/admin` |
| MixMO（手机 App 设计） | `https://NAS_IP:8443/mixmo` | 需套件内有 `mixmo/`（官方 2026-10-15 包内置） |
| MQTT | `NAS_IP:1883` | 设备接入 |
| WebSocket MQTT | `NAS_IP:8083 / 8084` | 明文 / 加密 |
| Yjs 协同 | `NAS_IP:8082 / 8086` | 明文 / 加密 |

- 管理员默认 `admin/public`，**对外开放前务必先做[安全加固](#安全加固对外开放前必做)**。
- Mixly 界面内按 **CTRL+SHIFT+M** 可随时调出管理后台。

---

## 管理后台走 `/admin`

18084 管理端是**独立的 express 应用**，所有路由都按根路径注册（`/` 登录页、`/admin` 面板、`/adminLogin`、`/js/…`），首页"管理后台"链接也拼成 `https://<当前主机>:18084`。所以套了域名 + 反代后，点它仍会跳到带端口的地址。设一个环境变量即可（compose 已启用）：

```yaml
    environment:
      - TZ=Asia/Shanghai
      - MIXIO_ADMIN_BASE=/admin
```

入口脚本每次启动自动做三处适配（未设置时完全不改官方文件）：

1. 管理端路由剥掉 `/admin` 前缀：`/admin/` 登录页、`/admin/admin` 面板、`/admin/js/…` 静态资源、`/admin/api/…` 在线更新接口；
2. 管理端模板注入 `<base href="/admin/">` 并把根路径 URL 相对化，同时注入一段运行时兜底脚本（改写页面里 `fetch` / `XMLHttpRequest` / `EventSource` 的根路径 URL）；未登录跳 `/admin/`（不再弹回 MixIO 首页）；
3. 首页"管理后台"链接：标准端口（443 / 无端口）指向 `/admin`，其它端口仍指 `:18084`（本地直连 8443 不受影响）。

> **为什么还要运行时兜底**：官方不同版本里同一处调用的写法会变（反引号 / 单引号 / 双引号模板串、字符串拼接），靠 `sed` 逐条改写必然会漏——漏一条就是一个 404。注入的脚本以页面为单位统一改写，不依赖写法，官方以后新增接口也自动覆盖。已相对化的 URL 原样放行，`https://…` 与 `//cdn…` 不动。

> **在线更新**（面板里的“检查更新 / 一键更新”）调的是 `POST /api/check-update` 和 `GET /api/download`（EventSource 推 SSE 进度），两个都是根路径，不处理就会 404。另外更新包会把 `mixio.js`、`ejs/`、`js/` 整包替换、补丁标记丢失，而更新只重启 node 进程、不重启容器——入口脚本因此挂了个 5 秒轮询的观察者，检测到标记丢失就自动重打（日志：`检测到运行包被在线更新覆盖`）。模板是 `ejs.renderFile` 每次读盘，改完立即生效；`mixio.js` 要进程重启才生效，更新流程本身会重启进程，通常正好接上。万一更新后 `/admin` 仍 404，`docker compose restart mixly` 一次即可。

**启用方式（三选一）**

```bash
# A. 换新镜像（推荐）
docker compose pull && docker compose up -d

# B. 不重建镜像：把入口脚本挂进容器
#    volumes:
#      - ./mixly_server:/opt/mixly_server
#      - ./docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro

# C. 裸机 / 群晖直接跑官方包：对套件根目录执行独立脚本
./patch-admin-base.sh /path/to/MixSuite-linux-x64 /admin
```

三种方式都只改程序文件、不动数据；首次执行前自动备份 `*.mixly-docker-orig`，官方在线更新覆盖后下次启动自动重打（幂等）。

### 反向代理要点

Nginx（`/admin` → 18084、`/` → 8443）：

```nginx
location /admin {
    proxy_pass https://127.0.0.1:18084;   # 不带尾斜杠、不带 URI，路径原样转发
    proxy_ssl_verify off;                  # 18084 是自签证书
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location / {
    proxy_pass https://127.0.0.1:8443;
    proxy_ssl_verify off;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";   # WebSocket（MQTT 的 8083/8084）
    proxy_read_timeout 86400;
}
```

- `location /admin` 必须用**前缀匹配**——写成 `/admin/` 会漏掉 `/admin` 本身。
- `proxy_pass` **不能**带 `/` 或 `/admin`，否则 Nginx 先剥一次前缀、补丁再剥一次。
- 上面端口都是**宿主机端口**。若 compose 写 `"18443:8443"`、`"18484:18084"`，两个 location 要分别指向 18443 / 18484，不能混。用 `docker port <容器名>` 查实际映射（必须能看到 18084 那行，没发布就无从转发）。

**Cloudflare 隧道**：面板 **Tunnels → 路由** 支持路径规则，且回源是 cloudflared 从内网发起的连接，**不受公网端口白名单约束**。真正的坑是**顺序**——面板从上到下第一个匹配生效，纯主机名那条会吃掉所有路径：

| 顺序 | 目标 | 服务 | 其他 |
|---|---|---|---|
| 1 | `mixly.example.com/admin` | `https://10.10.64.4:18084` | TLS → No TLS Verify |
| 2 | `mixly.example.com` | `https://10.10.64.4:8443` | 默认 |

**故障判别**：`/admin` 返回 `Cannot GET /admin`（Express 兜底 404）= 请求进了**主站**，主站没有该路由。查 `/admin` 的 `proxy_pass` 是否误指主站端口、或 CF 路由里主机名规则排在前面。细分：`/admin`、`/admin/`、`/adminLogin` **三者全 404** → 顺序错；只有 `/admin` 404 而 `/admin/` 正常 → 写成了精确匹配。

**备选：独立子域名**（旧面板无路径规则、或 DSM 反向代理只能按域名分时）

面板加一条公共主机名 `admin.example.com → https://<内网IP>:18084`（TLS 勾 **No TLS Verify**），compose 补一行 `- MIXIO_ADMIN_URL=https://admin.example.com/`。**不要删 `MIXIO_ADMIN_BASE`**——卷内模板已注入 `<base href="/admin/">`，两者共存才安全（带前缀则剥离、不带原样通过）。裸机等价：`./patch-admin-base.sh <目录> '' https://admin.example.com/`。

> Cloudflare 只代理标准端口，`https://域名:18084` 本身打不开。Mixly 编辑器内 **CTRL+SHIFT+M** 的入口在官方静态资源里、不在本补丁范围内。

---

## 安全加固（对外开放前必做）

默认 `admin/public` + 管理端挂在公网 = 任何人知道地址就能进后台（改配置、清数据、停服务）。按顺序做这三件事。

### 1. 改管理员密码

**方式 A：管理面板**（推荐，立即生效）

`https://域名/admin` 登录 → **基础管理**（`/admin/admin?page=basic`）→ 配置表里的 `ADMIN_PASSWORD` 行改掉 → 点 **保存设置并重新启动**。面板会把配置写回 `mixio-app/config/config.json` 并在进程内重启 MixIO（几秒，容器不重启）。

**方式 B：改文件**（直接在服务器上操作）

```bash
docker stop mixly-server
# 编辑 <映射路径>/mixio-app/config/config.json 中的 ADMIN_PASSWORD
docker start mixly-server
```

> ⚠️ **必须停容器再改文件**。进程只在启动时读一次配置；若你改完文件又在面板点了"保存设置并重新启动"，面板会用内存里的旧值**覆盖**你的修改。
>
> ⚠️ 密码在 `config.json` 中是**明文**（官方实现，登录时直接 `==` 比较）。该文件在映射目录里，别把目录共享出去，备份与截图注意脱敏。

### 2. 给 `/admin` 套一层 Cloudflare Access

即使密码泄露，也先挡住整个后台：

1. Zero Trust → **Access → Applications** → **Add an application** → **Self-hosted**。
2. Application domain 填 `mixly.example.com`，Path 填 `admin`（保护 `/admin` 及其全部子路径）。
3. **Add a policy**：Action `Allow`，Include → **Emails** → 填你自己的邮箱。
4. 保存。之后访问 `/admin` 会先要求邮箱验证码（One-time PIN，无需配置 IdP），通过后才到 MixIO 登录页。

> 用了子域名方案就给那个主机名单独建一条应用；Access 的授权 cookie 按路径生效，静态资源与 AJAX 一并覆盖。

### 3. 收敛暴露面

| 项 | 建议 |
|---|---|
| `18084` | **不要**在路由器/防火墙上直接映射到公网，只经 `/admin` 反代或隧道进入 |
| `1883` / `8083` / `8084` | MQTT 侧内置 `MixIO_public` / `MixIO_public` 通用账号（供未注册设备接入），仅适合内网或经隧道暴露 |
| `ALLOW_REGISTER` | 只给内部账号用时设为 `false`（面板配置页可改），否则任何人都能注册 |
| `/admin/adminLogin` | 该接口没有失败锁定，可在 Cloudflare 加一条 Rate limiting 规则（如 10 次/分钟）兜底 |

> 管理员登录态 5 小时过期；改密码后已登录的旧会话在过期前仍有效，急用可重启 MixIO。

---

## 升级 MixSuite 运行包（保留数据）

官方更新较快（例如 2026-10-15 版才内置 `mixmo/`），换包时**只覆盖程序文件、保留数据目录**：

```bash
# 1) 停容器
docker rm -f mixly-server

# 2) 备份数据（SQLite 用户/项目、证书、配置都在这里）
cp -a <映射路径>/mixio-app/storage <映射路径>/mixio-app/storage.bak
cp -a <映射路径>/mixio-app/config  <映射路径>/mixio-app/config.bak

# 3) 解压新包并覆盖程序文件 —— 不要动 storage / config / logs / runtime
unzip -o ~/Downloads/MixSuite-linux-x64.zip -d /tmp/mixnew
cp -a /tmp/mixnew/MixSuite-linux-x64/. <映射路径>/
# 若上一步覆盖了数据目录，把备份放回：
# rm -rf <映射路径>/mixio-app/storage && mv <映射路径>/mixio-app/storage.bak <映射路径>/mixio-app/storage

# 4) 按原方式重新启动
```

可选组件（放套件根目录即可，与 `mixio-app/` 同级）：

| 产品 | 目录 | 入口 | 来源 |
|---|---|---|---|
| Mixly 图文编程 | `mixly/` | `/mixly` | MixSuite 内置 |
| MixCO 自学课程 | `mixco/` | `/mixco` | MixSuite 内置 |
| **MixMO 手机 App 设计** | `mixmo/` | `/mixmo` | MixSuite 内置（2026-10-15 起） |
| MixAI 交互体验 | `mixai/` | `/mixai` | **单独下载**后放进来 |
| MixNT 网络仿真 | `mixnt/` | `/mixnt` | 随包内嵌或单独放置 |

> 官方 2026-10-15 版的桌面壳与管理端已接入 MixMO，但服务端 `mixio.js` 尚未挂载 `/mixmo` 路由。本镜像 v2.3.0 起会在启动时对卷内 `mixio.js` 打**幂等补丁**（备份 `mixio.js.mixly-docker-orig`，插入块带 `MIXLY_DOCKER_MIXMO_PATCH` 标记），补上静态挂载与首页入口；卷里没有 `mixmo/` 时 `/mixmo` 自然 404、无副作用，放入后**无需重启**即生效。

---

## 架构兼容

官方按机型提供 `MixSuite-linux-<架构>.zip`（包内启动文件同名 `MixlyServer`），不清楚自己机型架构可咨询主机厂家：

| 机器架构 | 运行包 | 镜像 |
|---|---|---|
| x64（Intel/AMD 群晖、PC） | `MixSuite-linux-x64.zip` | 多架构 manifest，直接 `docker pull` |
| arm64（ARM 群晖、国产信创电脑） | `MixSuite-linux-arm64.zip` | 同上 |
| loong64（龙芯） | `MixSuite-linux-loong64.zip` | 同上 |

容器启动时入口脚本解析 `.host/nw` 的 ELF 头，**自动校验架构是否匹配**：下错压缩包会明确提示该去下载哪个架构，而不是抛难懂的加载器错误（拉镜像报 `exec format error` 时也先查这一项）。

容器内通过 **Xvfb 虚拟显示**运行 NW.js 图形壳（服务本身不依赖显示，浏览器访问不受影响）；想操作这个本地窗口，可自行在容器里装 `x11vnc`。

## 烧录硬件（串口/USB）

Mixly 通过串口给开发板烧录。容器内以非 root 运行，透传 USB 设备后还需串口权限，在 `docker-compose.yml` 中取消注释：

```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
    group_add:
      - dialout
```

⚠️ **`devices` 是按需开启，不是必填项**——Docker 要求宿主机上**真实存在**该设备节点，否则直接拒绝启动：

```
Error gathering device information while adding custom device "/dev/ttyUSB0": no such file or directory
```

- **没插开发板 / 暂时不烧录** → 删掉 `devices` 段（或 `--device` 参数），不影响其他功能
- **插了板子还报错** → 设备名可能不是 `ttyUSB0`，在宿主机 `ls /dev/ttyUSB* /dev/ttyACM*` 查真实名称（部分国产芯片是 `ttyACM0`）
- **群晖 DSM** → 还需在 Container Manager 套件设置里允许容器访问 USB 设备

（`docker run` 等价写法：`--device /dev/ttyUSB0 --group-add dialout`。）

## 本地构建（不用 GitHub Actions）

```bash
docker login ghcr.io
GHCR_USER=你的GitHub用户名 ./build-push.sh v2.0
```

构建 `linux/amd64` + `linux/arm64` + `linux/loong64` 三架构 manifest，`docker pull` 时按设备架构自动选择。

---

## 常见问题（FAQ）

**Q1：浏览器提示"连接不是专用连接 / 不安全"**

MixSuite 强制 HTTPS 且使用自签证书，属正常现象：点**高级 → 继续访问**即可。内网也可在 DSM/路由器做端口映射或反向代理套正式证书。

**Q2：容器起来就退出，日志提示"未检测到 Mixly 官方运行包"**

运行包没放对，或多套了一层目录。要放**文件夹里面的内容**（`MixlyServer`、`.host/`、`mixio-app/`），见[快速开始](#2-放置官方运行包)。

**Q3：容器显示 running，但网页打不开**

NW.js 外壳活着**不等于** MixIO 已就绪——初始化卡住时状态照样是 running。按顺序看三步：

```bash
# 1) 状态列：healthy = 8443 已有 MixIO 在服务；unhealthy/starting = 还没就绪
docker ps --format "table {{.Names}}\t{{.Status}}"
# 2) MixIO 自己的日志（NW 会把 console.log 吞进这个文件）
docker exec mixly-server sh -c 'tail -n 50 /opt/mixly_server/mixio-app/logs/*.log'
# 3) 端口有没有监听（8443=主入口，18084=管理端）
docker exec mixly-server sh -c "netstat -tlnp | grep -E '8443|18084'"
```

| 日志现象 | 原因 / 处理 |
|---|---|
| `Downloading certificate from https://mixly.org/...` 卡住 | 离线内网拉不到官方证书（两次 5 秒超时），等 10~30 秒；或把 `config.json` 的 `HTTPS_CRT_FILE`/`HTTPS_PRIVATE_PEM` 指向本地证书 |
| `EADDRINUSE` / 端口被占 | 旧进程残留或同机有其他实例，重建容器即可 |
| 日志出现「`/dev/shm` 仅 64MB」 | 加 `shm_size: '1gb'` / `--shm-size=1g` |

**Q4：容器反复重启，日志有 `Failed to create .../user-data/SingletonLock: Permission denied`**

NW.js（Chromium）要在 `user-data` 建 SingletonLock，写不进去就主动 Abort，重启策略再拉起来形成循环。根因是文件权限语义：**Docker Desktop（WSL2/virtiofs）、NFS、CIFS 上 `chown` 静默无效**（属主永远是 root）。最新镜像已用 `chmod a+rwX` + 启动前实测写入兜底并给出明确诊断，升级镜像即可；`user-data` 里的既有数据不受影响。

**Q5：日志里这些报错要不要管？**

以"浏览器能否打开 `https://IP:8443`"为准，不要以日志是否干净为准：

| 日志片段 | 性质 |
|---|---|
| `Failed to connect to the bus` / `org.freedesktop.DBus...` | 无害。容器内无 dbus daemon，Chromium 每次启动必报几十行 |
| `XGetWindowAttributes failed for window 0`（单独出现） | 无害噪音；但若紧邻"进程数秒内退出 + 退出码 0"，属窗口层故障，见 [README-docker.md](README-docker.md#排障存档短命-0-退出与启动策略轮换) |
| `chrome_crashpad_handler: --database is required` | 无害，NW.js 自带崩溃上报组件 |
| `handshake failed ... net_error -101` | 离线环境拉外部 HTTPS 资源失败，正常 |
| 完全没有 `Checking ports` / `Starting NW runtime` | 无害。官方启动器父进程 stdout 在管道下全缓冲，这些进度会随缓冲区丢失，看不到不代表没执行 |

**Q6：改了镜像 / 升级了版本，行为却没变？**

`docker run`、`docker compose up` 在本地已有同名 `latest` 时**不会**拉新镜像：

```bash
docker compose pull && docker compose up -d    # 或 docker pull 后删旧容器再起
```

**Q7：日志有 NTP/123 端口告警**

仅为功能告警（网络时间仿真），不影响服务与访问，可忽略；需要时在 compose 加 `cap_add: [NET_BIND_SERVICE]` 并映射 `123:123/udp`。

**Q8：容器反复重启、只活两三秒、日志几乎空白**

属 NW.js 窗口层故障（官方启动器的 ozone 参数在 Xvfb 下建不了窗口），**v2.2.0 起默认启动方式已避开**，升级镜像即可。仍遇到时重启循环会自动取证并轮换启动策略，把 `自动取证开始` 到 `自动取证结束` 之间的日志反馈；详细原理与诊断开关见 [README-docker.md](README-docker.md#排障存档短命-0-退出与启动策略轮换)。

---

## 从 v1.x（mixly_server）迁移

1. **备份**：复制原映射目录下的 `mixio/storage` 文件夹（SQLite 数据）。
2. **换包**：下载对应架构的 `MixSuite-linux-<架构>.zip`，解压后把内容放进映射目录（替换旧的 `mixio/` `mixly/` `mixco/` 布局）。
3. **带数据升级**：旧数据在 `mixio/storage`，新位置是 `mixio-app/storage`——把旧目录内容复制到新的 `mixio-app/storage/` 再启动。
4. **端口变化**：管理/访问入口从 `http://8080` 改为 `https://8443`（HTTP 官方已关闭），反代或端口映射记得改。
5. 升级镜像本身不丢数据（数据全在映射目录里），但**升级运行包前建议先停容器**。

---

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

# mixly-docker

[![docker-ci](https://github.com/RealKiro/mixly-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/RealKiro/mixly-docker/actions/workflows/ci.yml)

适配 [Mixly 米思齐](https://mixly.cn) **Mixly 4.0（MixSuite）** 离线服务端的 Docker 运行环境，支持群晖 NAS 等 **x64 / arm64 / loong64** 设备。

**镜像只含运行环境（约 300MB，Debian + NW.js/X11 依赖 + Xvfb 虚拟显示），不含官方运行包。** 使用者自行从官方百度网盘下载对应架构的 `MixSuite-linux-<架构>.zip`，解压后放入挂载目录，首次启动时容器会自动检测并给出放置指引。

> Mixly 4.0 起官方只有一个发行版：内置 MixIO 的 **MixSuite**（`MixlyServer`，NW.js 应用），替代了旧版的 `mixly_server`（`mixio` 单文件）。**强制 HTTPS**：HTTP(8080) 被官方固定关闭，请使用 `https://NAS_IP:8443` 访问。从 v1.x（mixly_server）升级请看[迁移说明](#从-v1xmixly_server-迁移)。
>
> 详细技术说明与本地构建方法见 [README-docker.md](README-docker.md)。

## 推荐使用方式：Star + Fork，推送到你自己的 GHCR

本项目不提供公共镜像，推荐每个使用者通过 GitHub Actions 把镜像构建到**自己账号**的 GHCR 下，拉取速度快、版本可控，也不依赖他人的仓库可用性。

### 1️⃣ Star 本仓库

如果这个适配对你有帮助，请先点一个 ⭐ Star，这是对作者最直接的支持，也方便你以后找到它。

### 2️⃣ Fork 到你的账号

点击右上角 **Fork**，把仓库复制到你的 GitHub 账号下。

### 3️⃣ 在 Fork 仓库中启用并运行构建

1. 进入你 Fork 的仓库 → **Actions** 标签页 → 按提示点击 **I understand my workflows, go ahead and enable them** 启用工作流。
2. 左侧选择 **docker-ci** → **Run workflow** → 运行。
   （也可以打一个 `v2.0` 标签推送来触发：`git tag v2.0 && git push origin v2.0`）
3. 构建几分钟完成（含 QEMU 模拟构建 arm64/loong64），成功后镜像为多架构 manifest，自动覆盖：

   ```
   ghcr.io/<你的GitHub用户名>/mixly-server:latest   # linux/amd64 + linux/arm64 + linux/loong64
   ```

   GHCR 登录使用 Actions 自带的 `GITHUB_TOKEN`，**无需配置任何 Secrets**。
   （可选：想同时推送到 Docker Hub，再在 Settings → Secrets and variables → Actions 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，未配置时自动跳过。）

### 4️⃣ 把 GHCR 包设为 Public（否则 NAS 拉取需要登录）

你的 GitHub 头像 → **Packages** → `mixly-server` → **Package settings** → **Change visibility** → Public。
（保持 Private 也可以，但 NAS 端需要先 `docker login ghcr.io`。）

### 5️⃣ 放置官方运行包并启动

1. **按你的机器架构**从官方百度网盘下载对应的压缩包（x64 / arm64 / loong64，不清楚可咨询主机厂家），解压后把**包内全部内容**放进该目录。放好后应存在：

   ```
   /docker/mixly/mixly_server/MixlyServer        （启动器）
   /docker/mixly/mixly_server/.host/nw           （NW.js 运行时）
   /docker/mixly/mixly_server/mixio-app/mixio.js （MixIO 服务端）
   /docker/mixly/mixly_server/mixly/             （Mixly 编辑器，建议保留）
   ```

   若容器反复重启并提示"未检测到运行包"，说明路径多套了一层 `MixSuite-linux-x64`——要把文件夹**里面的内容**放到映射目录（入口脚本对多套一层有自动兼容，但仍建议放对）。
2. 下载本仓库的 [docker-compose.yml](docker-compose.yml) 放到 `/docker/mixly/`，把 `image:` 改为你自己的镜像：

   ```yaml
   image: ghcr.io/<你的GitHub用户名>/mixly-server:latest
   ```

3. Container Manager → 项目 → 新增 → 选择该 compose 文件 → 启动。

> 内存与共享内存：NW.js 是完整 Chromium，Docker 默认 `/dev/shm` 只有 64MB，
> 不足会让渲染进程静默退出（容器每隔一两分钟自己重启、日志里看不到原因）。
> 本仓库的 compose 已内置 `shm_size: '1gb'`；若你用 `docker run` 请务必加
> `--shm-size=1g`，并给容器留 1.5GB 以上内存（群晖：容器设置 → 内存限制）。

### 6️⃣ 访问

| 入口 | 地址 | 说明 |
|---|---|---|
| MixIO / Mixly 主界面 | `https://NAS_IP:8443` | MixSuite 强制 HTTPS；自签证书提示"连接不是专用连接"时点**高级 → 继续访问** |
| MixMO（手机 App 设计） | `https://NAS_IP:8443/mixmo` | 需运行包内含 `mixmo/` 目录（官方 MixSuite 2026-10-15 起内置），入口见下方说明 |
| 管理模式 | `https://NAS_IP:18084` | 数据管理、用户导入、在线更新 |
| MQTT | `NAS_IP:1883` | 设备接入 |
| WebSocket MQTT | `NAS_IP:8083 / 8084` | 明文 / 加密 |
| Yjs 协同 | `NAS_IP:8082 / 8086` | 明文 / 加密 |

- **HTTP(8080) 已不可用**：MixSuite 每次启动都会把 HTTP 端口固定改写为 0，只能走 HTTPS。
- 管理员默认 `admin/public`，**上线后务必在 `mixio-app/config/config.json` 中修改 `ADMIN_PASSWORD`**；离线内网可保留 `ALLOW_REGISTER`。如需外网访问，在 DSM 控制面板做端口映射或用 DSM 反向代理套 443。
- Mixly 界面内按 **CTRL+SHIFT+M** 可随时调出管理后台。

#### 反向代理：管理后台走 `/admin`

18084 管理后台是独立的 express 应用，所有路由（`/` 登录页、`/admin` 面板、`/adminLogin`、`/js/…`）都按根路径注册；首页“管理后台”链接也会拼成 `https://<当前主机>:18084`。要让它在**同一域名**下走 `/admin`（Cloudflare Tunnel / Nginx 反代），设置一个环境变量即可：

```yaml
    environment:
      - TZ=Asia/Shanghai
      - MIXIO_ADMIN_BASE=/admin
```

入口脚本每次启动会自动做三处适配（未设置时完全不改动官方文件）：

1. 管理端路由剥掉 `/admin` 前缀：`/admin/` = 登录页、`/admin` = 面板、`/admin/js/…` = 静态资源；
2. 管理端模板注入 `<base href="/admin/">` 并把根路径改成相对路径，未登录时跳转到 `/admin/`（而不是跳回 MixIO 首页）；
3. 首页“管理后台”链接：标准端口（443/无端口）指向 `/admin`，其它端口仍指向 `:18084`（本地直连 8443 不受影响）。

启用方式（三选一）：

```bash
# A. 用新镜像重新创建容器（推荐，镜像需包含本版入口脚本）
docker compose pull && docker compose up -d

# B. 不重建镜像：临时把入口脚本挂进容器，改完 compose 后 up -d
#    volumes:
#      - ./mixly_server:/opt/mixly_server
#      - ./docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro

# C. 不用 Docker（裸机 / 群晖直接跑官方包）：对套件根目录执行独立补丁脚本
#    （与入口脚本同一套逻辑，幂等；官方在线更新后重跑一次即可重新生效）
/path/to/patch-admin-base.sh /path/to/MixSuite-linux-x64 /admin
```

> 三种方式都只改程序文件、不动数据；首次执行前自动备份 `*.mixly-docker-orig`。

管理端登录后地址是 `/admin/admin`（面板），首页链接是 `/admin`——两者都能用，静态资源与 AJAX 都按前缀解析。

反向代理侧要点（Cloudflare Tunnel 示例）：

```yaml
# cloudflared config.yml
ingress:
  - hostname: mixly.example.com
    path: ^/admin(/.*)?$          # path 是 Go 正则：匹配 /admin 及其全部子路径
    service: https://localhost:18084
    originRequest:
      noTLSVerify: true           # 18084 是自签证书
  - hostname: mixly.example.com
    service: https://localhost:8443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

Nginx 示例（域名 443 → 容器；主站 `/` 走 8443、`/admin` 走 18084）：

```nginx
server {
    listen 443 ssl;
    server_name mixly.example.com;
    # ...ssl_certificate / ssl_certificate_key / http2 等按你的证书配置...

    # 管理后台：https://域名/admin → 容器 18084
    location /admin {
        proxy_pass https://127.0.0.1:18084;   # 容器/宿主机地址按实际改
        proxy_ssl_verify off;                  # 18084 是自签证书
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # MixIO 主站
    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_ssl_verify off;                  # 8443 同为自签证书
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";  # WebSocket(MQTT 1883 的 8083/8084 协同)
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }
}
```

> **关键**：`location /admin` 用前缀匹配覆盖 `/admin`、`/admin/`、`/admin/js/…`、`/admin/admin` 全部子路径；`proxy_pass` 写成 `https://127.0.0.1:18084`（**不带尾斜杠、不带 URI**），把路径**原样**转发给 18084——前缀由 `MIXIO_ADMIN_BASE` 补丁在应用侧剥离。若写成 `proxy_pass https://127.0.0.1:18084/;`（带尾斜杠）或 `.../admin;`，Nginx 会先剥掉 `/admin` 前缀，反而与补丁冲突。
> 另外 cloudflared 的 `path` 不是通配符而是 Go 正则，写 `/admin*` 只会匹配 `/admin`、`/adminn`，不会匹配 `/admin/js/…`。两类反代都**不剥离路径**、原样转发给 18084——这正是需要 `MIXIO_ADMIN_BASE` 在应用侧剥前缀的原因。

> **改了宿主机端口映射时**：上面 `127.0.0.1:8443` / `127.0.0.1:18084` 指的都是**宿主机端口**，不是容器内端口。若 compose 里写成 `"18443:8443"`、`"18484:18084"`，则 `location /` 要指向 `https://127.0.0.1:18443`，`location /admin` 要指向 `https://127.0.0.1:18484`——两个端口**不能混用**。用 `docker port <容器名>` 可查实际映射（务必确认 18084 那一行存在，没发布就无从转发）。
>
> 反过来，这也是**最快的故障判别法**：访问 `/admin` 若返回 `Cannot GET /admin`（Express 兜底 404 文案），说明请求进了**主站**而不是管理端——主站没有任何 `/admin` 路由；18084 上该路由是存在的，未登录会 `302` 到 `/admin/`。此时查 `/admin` 的 `proxy_pass` 是否误指到主站端口。

访问顺序：`https://mixly.example.com/admin` → 未登录跳到 `/admin/`（登录页）→ 登录后进入 `/admin/admin`（面板）。管理端所有 AJAX、静态资源与跳转都已按前缀处理。

#### 方案二：管理端独立子域名（Cloudflare 面板隧道 / DSM 反向代理）

**什么时候必须用这个**：路径模式要求入口能按路径分流、且能回源到 18084。但

- Cloudflare 代理只支持固定端口（443、2053、2083、2087、2096、8443），**18084 不在列表**，所以**不能**用 Origin Rules 把 `/admin` 的源站端口改成 18084；
- Zero Trust 面板管理的隧道只有「公共主机名 → 服务」，**不支持按路径分流**；
- DSM 的「登录门户 → 高级 → 反向代理」也只能按域名分。

三者叠加的结果就是：`/admin` 被整体送到主站，返回 `Cannot GET /admin`（Express 兜底 404，主站没有该路由）。

做法：给管理端单独一个子域名，它的根路径就是登录页。

1. Zero Trust → Networks → Tunnels → 你的隧道 → **Public Hostname → Add**：
   - Subdomain 填 `admin`，Domain 选你的主域（示例：`admin.mixly.example.com`）
   - Service：`HTTPS` → `10.10.64.4:18084`（cloudflared 与 NAS 同机时写 `localhost:18084`）
   - Additional application settings → TLS → 勾上 **No TLS Verify**（18084 是自签证书）
2. compose 里补一行（**不必删掉** `MIXIO_ADMIN_BASE`）：
   ```yaml
   - MIXIO_ADMIN_URL=https://admin.mixly.example.com/
   ```
3. `docker compose up -d` 重建容器。

之后 `https://admin.mixly.example.com/` 是登录页，`/admin` 是面板；首页“管理后台”按钮直接指向它。两个变量共存是安全的——请求带 `/admin` 前缀就剥离、不带就原样通过，路径与子域名两种入口可同时使用。

> 裸机部署等价命令：`./patch-admin-base.sh /path/to/MixSuite-linux-x64 '' https://admin.mixly.example.com/`（第二个参数留空即子域名模式，不做任何前缀改写）。

> Cloudflare 只代理标准端口，`https://域名:18084` 本身是打不开的；Mixly 编辑器内的 **CTRL+SHIFT+M** 入口在 MixSuite 的 `mixly/` 静态资源里，不在本补丁范围内——如果它也跳到 `:18084`，请反馈。


#### MixSuite 产品矩阵（官方 2026-10-15 包）

官方已把多个产品统一进 MixSuite 压缩包，**解压即用**（都是套件根目录下与 `mixio-app/` 同级的旁路目录，MixIO 按请求动态挂载、无需重启）：

| 产品 | 目录 | 入口 | 官方包 |
|---|---|---|---|
| Mixly 图文编程 | `mixly/` | `https://NAS_IP:8443/mixly` | MixSuite 内置 |
| MixIO 平台（本服务主体） | `mixio-app/` | `https://NAS_IP:8443` | MixSuite 内置 |
| MixCO 自学课程 | `mixco/` | `https://NAS_IP:8443/mixco` | MixSuite 内置 |
| **MixMO 手机 App 设计** | `mixmo/` | `https://NAS_IP:8443/mixmo` | MixSuite 内置（2026-10-15 起） |
| MixAI 交互体验 | `mixai/` | `https://NAS_IP:8443/mixai` | **单独下载**，解压后放进套件根目录（官方说明：包比较大，需单独下载解压放进去） |
| MixNT 网络仿真 | `mixnt/` 或 `mixly/mixvm/mixnt/` | `https://NAS_IP:8443/mixnt` | 随 Mixly/MixCO 包内嵌或单独放置 |

> **MixMO 说明（v2.3.0 起）**：官方 2026-10-15 版的桌面壳菜单和 18084 管理端已接入 MixMO，但服务端 `mixio.js` 尚未挂载 `/mixmo` 路由、首页也不显示入口（官方模板已留防御式代码，等服务端版本补齐）。本镜像的入口脚本会**自动给卷内 `mixio.js` 打幂等补丁**（备份 `mixio.js.mixly-docker-orig`，插入块带 `MIXLY_DOCKER_MIXMO_PATCH` 标记；官方在线更新覆盖 `mixio.js` 后下次启动自动重打），补上 `/mixmo` 静态挂载与首页入口。卷里没有 `mixmo/` 时 `/mixmo` 自然返回 404、无副作用；把 `mixmo/` 放进卷后也**无需重启容器**。

## 从 v1.x（mixly_server）迁移

1. **备份**：复制原映射目录下的 `mixio/storage` 文件夹（SQLite 数据）。
2. **换包**：下载新架构对应的 `MixSuite-linux-<架构>.zip`，解压后把内容放进映射目录（替换旧的 mixio/ mixly/ mixco/ 布局）。
3. **带数据升级**（保留用户/项目）：旧数据在 `mixio/storage`，新位置是 `mixio-app/storage`——把旧 `mixio/storage` 里的内容复制到新的 `mixio-app/storage/`，再启动。
4. **端口变化**：管理/访问入口从 `http://8080` 改为 `https://8443`（HTTP 官方已关闭）；若用了反向代理或端口映射，记得改。
5. 升级镜像本身不丢数据（数据全在映射目录里），但**升级 MixSuite 运行包前建议先停容器**。

## 升级 MixSuite 运行包（保留用户数据）

官方 MixSuite 更新较快（例如 2026-10-15 版才内置 `mixmo/`），换包时**只覆盖程序文件、保留数据目录**：

```bash
# 1) 停容器
docker rm -f <你的容器名>

# 2) 备份数据目录（SQLite 用户/项目、证书、配置都在这里）
cp -a <映射路径>/mixio-app/storage <映射路径>/mixio-app/storage.bak
cp -a <映射路径>/mixio-app/config  <映射路径>/mixio-app/config.bak

# 3) 解压新包到临时目录，覆盖程序文件，但【不要】动 storage / config / logs / runtime
#    （以 Linux 为例；Windows 下用资源管理器同样只复制除上述目录外的内容）
cd <映射路径>
unzip -o ~/Downloads/MixSuite-linux-x64.zip -d /tmp/mixnew
cp -a /tmp/mixnew/MixSuite-linux-x64/. <映射路径>/
# 然后把备份的 storage/config 放回（若上一步被覆盖）：
# rm -rf <映射路径>/mixio-app/storage && mv <映射路径>/mixio-app/storage.bak <映射路径>/mixio-app/storage

# 4) 按原有方式重新启动容器
```

- 想用 **MixAI**：从官方渠道单独下载 MixlyAI 包，解压后把 `mixai/` 放进套件根目录（与 `mixio-app/` 同级）即可，**无需重启**，首页会自动出现入口。
- 想用 **MixMO**：确认套件根目录有 `mixmo/`（2026-10-15 起官方包内置），访问 `https://NAS_IP:8443/mixmo`。
- 入口脚本每次启动都会重新校验 `mixio.js` 的补丁标记，官方在线更新覆盖后自动重打，无需手工干预。

## 本地构建（不用 GitHub Actions）

```bash
docker login ghcr.io
GHCR_USER=你的GitHub用户名 ./build-push.sh v2.0
```

构建 `linux/amd64` + `linux/arm64` + `linux/loong64` 三架构 manifest，`docker pull` 时按设备架构自动选择。

## 架构与兼容性说明

官方按机型提供 `MixSuite-linux-<架构>.zip`（各架构包内启动文件同名 `MixlyServer`），不清楚自己机型架构可咨询主机厂家：

| 机器架构 | 运行包来源 | 镜像 |
|---|---|---|
| x64（Intel/AMD 群晖、PC） | 官方网盘 `MixSuite-linux-x64.zip` | 多架构 manifest 直接 `docker pull` |
| arm64（ARM 群晖、国产新创电脑） | 官方网盘 `MixSuite-linux-arm64.zip` | 多架构 manifest 直接 `docker pull` |
| loong64（龙芯电脑） | 官方网盘 `MixSuite-linux-loong64.zip` | 多架构 manifest 直接 `docker pull` |

容器启动时入口脚本会解析运行包 `.host/nw` 的 ELF 头，**自动校验架构与机器是否匹配**：下错压缩包会明确提示该去下载哪个架构，而不是报出难懂的加载器错误。

容器内通过 **Xvfb 虚拟显示**运行 NW.js 图形壳（服务本身不依赖显示，浏览器访问不受影响）；需要查看/操作这个本地窗口时，可自行在容器里装 `x11vnc` 或改用带 VNC 的镜像。

## 烧录硬件（串口/USB）

Mixly 通过串口给开发板烧录程序。容器内服务以非 root 运行，透传 USB 设备后还需串口权限，在 `docker-compose.yml` 中取消注释：

```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
    group_add:
      - dialout
```

⚠️ **`devices` / `--device` 是"按需开启"，不是必填项**：Docker 要求宿主机上必须**真实存在**该设备节点，否则直接报错拒绝启动：

```
Error gathering device information while adding custom device "/dev/ttyUSB0": no such file or directory
```

- **没插开发板 / 暂时不烧录** → 删掉 `devices` 段（compose）或 `--device` 参数（docker run），不影响其他功能
- **插了板子还是报错** → 设备名可能不是 `ttyUSB0`，在宿主机执行 `ls /dev/ttyUSB* /dev/ttyACM*` 查看真实名称（部分国产芯片是 `ttyACM0`）
- **群晖 DSM** → 还需在 Container Manager 套件设置里允许容器访问 USB 设备，否则即使设备存在也透传不进去

（设备文件名按实际为准；`docker run` 命令行等价写法：`--device /dev/ttyUSB0 --group-add dialout`。）

## 常见问题（FAQ）

**Q1：`docker run` 报 `Error gathering device information while adding custom device "/dev/ttyUSB0": no such file or directory`，容器起不来**

宿主机上没有 `/dev/ttyUSB0` 这个设备节点（没插板子或设备名不同）。`--device` / `devices:` 是**按需开启项**，没插开发板就删掉该参数即可；插了板子就在宿主机 `ls /dev/ttyUSB* /dev/ttyACM*` 按真实名称填写。

**Q2：浏览器打开 `https://IP:8443` 提示"连接不是专用连接 / 不安全"**

MixSuite 强制 HTTPS 且使用自签证书，属正常现象：点**高级 → 继续访问**即可。内网使用时也可在 DSM/路由器上做端口映射或反向代理套正式证书。

**Q3：容器起来就退出，日志提示"未检测到 Mixly 官方运行包"**

映射目录里没有放对运行包，或多套了一层目录。要把 `MixSuite-linux-<架构>` 解压后**文件夹里的内容**（`MixlyServer`、`.host/`、`mixio-app/`）直接放进映射目录；入口脚本对多套一层有自动兼容，但仍建议放对。

**Q4：HTTP 8080 打不开**

Mixly 4.0 起官方把 HTTP 端口固定改写为 0，**只能用 HTTPS 8443**，这是官方行为。

**Q5：日志有 NTP/123 端口相关告警**

仅为功能告警（网络时间仿真），不影响 MixIO 主服务与浏览器访问，可忽略。

**Q6：容器日志停留在 Xvfb/nw 相关输出，界面操作无响应**

NW.js 图形壳跑在 Xvfb 虚拟显示上（`:99`），服务本身不依赖它；若确认壳异常，可进容器 `docker exec -it <容器名> bash` 后 `DISPLAY=:99 xwininfo -root` 检查窗口是否创建。

**Q7：龙芯（loong64）机器拉镜像报 exec 格式错误**

确认下载的是 `MixSuite-linux-loong64.zip` 运行包，且镜像 tag 为 v2.0 及以上（多架构 manifest 已含 loong64）；容器启动时入口脚本会校验 `.host/nw` 的 ELF 架构，下错包会给出明确提示。

**Q8：容器反复重启，日志有 `Failed to create .../user-data/SingletonLock: Permission denied`**

NW.js（Chromium）要在 `user-data` 目录创建 SingletonLock，写不进去就主动 Abort，宿主机重启策略再拉起来，形成循环。根因是运行平台的文件权限语义：**Docker Desktop（Windows/macOS 的 WSL2/virtiofs）、NFS、CIFS 挂载卷上 `chown` 静默无效**（属主永远是 root），降权后的 mixly 用户写不进 755 的 user-data。

**用 v2.0.1 及以上镜像即可**（入口脚本已改为 `chmod a+rwX` 权限位兜底 + 启动前实测写入，失败会给出明确诊断而非无限重启）。若你还在用 v2.0，升级镜像后重启容器；`user-data` 里已有的数据不受影响。

>补充：升级到最新版（v2.0.8+）后请直接用 `latest`。若容器仍在重启，先排除这一类权限问题，再看 Q11——两者的日志特征完全不同（Q8 有 `SingletonLock: Permission denied`，Q11 是空白、`EACCES ... mkdir` 或只活几秒）。另注意：`docker run` / `compose up` 不会自动拉取新版 `latest`，升级必须先 `docker pull` 再删旧容器。

**Q9：日志里这些报错要不要管？**

v2.0.2 起，容器正常运行时日志里只会剩下**无害噪音**，可对照下表判断：

| 日志片段 | 性质 |
|---|---|
| `dbus/bus.cc: Failed to connect to the bus` / `org.freedesktop.DBus...` | 无害。容器内无 dbus daemon，Chromium 每次启动必报几十行 |
| `XGetWindowAttributes failed for window 0` | **单独出现时无害**（Xvfb 下的窗口告警，窗口 ID 非零时是良性噪音）；但若它紧邻「进程数秒内退出 + 退出码 0」，则是窗口层故障的信号——v2.1.0 已定位根因（官方启动器的 `--ozone-platform=x11` 在 Xvfb 下建不了窗口），v2.2.0 起默认改用不带 ozone 的直连方式，该故障不再出现，见 Q11 路径 3 |
| 完全没有 `Checking ports` / `Starting NW runtime` / `Loading MixIO service` | 无害。官方启动器父进程的 stdout 在管道下全缓冲，这些进度会随缓冲区丢失，**看不到不代表没执行**；见 Q11 路径 4 |
| `chrome_crashpad_handler: --database is required` | 无害。崩溃上报组件，NW.js 自带 |
| `Fontconfig error: No writable cache directories` / `Failed to create .../pki/nssdb` | **v2.0.1 及更早会出现**；v2.0.2 已预建可写的 `.cache` / `.local/share` 与 XDG 目录，升级后消失 |
| `handshake failed ... net_error -101` | 离线内网环境下拉取外部 HTTPS 资源失败，属正常。若 `https://IP:8443` 能正常打开界面即可忽略；打不开才需排查 |

判断容器是否真正可用，以「浏览器能否打开 `https://IP:8443`」为准，而不是以日志是否干净为准。

**Q10：容器显示 running，但网页打不开（服务没起来）怎么排查？**

NW.js 外壳活着**不等于** MixIO 服务已就绪——初始化卡住时容器状态照样是 running。v2.0.3 起镜像带健康检查，按顺序看这三步：

```bash
# 1) 状态列：healthy = 8443 已有 MixIO 在服务；unhealthy/starting = 还没就绪
docker ps --format "table {{.Names}}\t{{.Status}}"

# 2) MixIO 自己的启动日志（关键，NW 会把 console.log 吞进这个文件）
docker exec <容器名> sh -c 'tail -n 50 /opt/mixly_server/mixio-app/logs/*.log'

# 3) 端口到底有没有监听（8443=HTTPS 主入口，18084=管理）
docker exec <容器名> netstat -tlnp | grep -E '8443|18084'
```

常见原因与对策：

| 第 2 步日志关键字 | 原因 | 对策 |
|---|---|---|
| `Downloading certificate from https://mixly.org/...` 后卡住 / 反复 handshake 失败 | 离线内网拉不到官方证书（每个 5 秒超时，共两次） | 等 10~30 秒；急用可断开启动时的外网请求，或在 `mixio-app/config/config.json` 把 `HTTPS_CRT_FILE`/`HTTPS_PRIVATE_PEM` 指向本地证书文件（不填 http:// 开头即走本地路径） |
| 无日志、`logs/` 为空 | MixIO 还没进入初始化 | 先确认第 1 步不是 `starting`，再看第 3 步端口 |
| `EADDRINUSE` / 端口被占 | 同容器内端口冲突或旧进程残留 | `docker exec <容器名> sh -c 'cat /opt/mixly_server/mixio-app/pid.info'` 看 PID 是否存在；容器重建即可清干净 |
| 日志出现「警告: /dev/shm 仅 64MB」 | 入口脚本已检测到共享内存不足 | compose 加 `shm_size: '1gb'`、`docker run` 加 `--shm-size=1g`，并留1.5GB+ 内存 |
| 容器约 120 秒后重启、退出码 0、日志无任何报错（连 `[mixio]` 都没有） | **MixIO 初始化抛错且异常被吞**，见下方 Q11 | 按Q11 逐条取证；v2.0.6 起会自动打印 `runtime/nw-main-error.log`，多数情况升级到 v2.0.8 即可 |
| `EACCES: permission denied, mkdir '.../mixio-app/store'` | `mixio-app` 目录本身对 mixly 用户不可写（`chown` 在 virtiofs/NFS 上无效） | 升级到 v2.0.7+；或在宿主机 `chmod -R a+rwX <mixly-app 所在目录>` |
| 容器**只活几秒**就重启、退出码 0、日志有 `XGetWindowAttributes failed for window 0`，且 `nw-main-error.log` 无新内容 | **NW 壳/窗口层故障**（窗口句柄为 0，从未创建成功），见 Q11 路径 3 | 升级到 v2.2.0：默认启动方式已避开该根因；若仍遇到，重启循环会自动取证并轮换启动策略，把 `自动取证开始` 到 `自动取证结束` 之间的日志反馈即可 |

**Q11：容器反复自动重启、退出码 0，`docker logs` 里看不到真实原因**

这是 Mixly 4.0 官方包在容器里的一个已知启动链缺陷，**不是你的配置错了**，也不是 `/dev/shm` 或证书问题。根因在 `mixio-app/mixio.js`：

```
 mixio.js:929    if (!fs.existsSync(storage)) { ...建库、写 filter.json... }
 mixio.js:920    mkdir logs      L923 mkdir store      L926 mkdir config
 mixio.js:6756   JSON.parse(fs.readFileSync(filterPath))     ← 无 try/catch
 mixio.js:7683   daemon_start().then(() => startOnce())     ← 无 .catch
 nw-boot.html    探测 8443，120 次 × 500ms 失败后放弃 → 退出码 0
```

**四个已实测确认的触发路径**（前两条症状几乎相同，后两条表现为「数秒即重启」）：

1. **`filter.json` 缺失**（v2.0.6 修复）。官方**只在 `storage` 目录不存在时**才创建 `filter.json`；而容器为了 `chown`/`chmod` 会预先建好 `storage`，官方因此认为「已初始化」而跳过创建 → 6756 行读 `filter.json` 得到 `ENOENT` 并抛错。

2. **`mixio-app` 目录本身不可写**（v2.0.7 修复）。官方 `init()` 要顺序新建 `logs`/`store`/`config`/`config/certs`，其中 `store` 就在 `mixio-app` 下面。若 `chown` 在 Docker Desktop(WSL2/virtiofs)/NFS/CIFS 上静默无效，`mixio-app` 保持 root:root 755，mixly 用户建不了 `store`，`init()` 在最前面就 `EACCES` 抛错：

   ```
   Error: EACCES: permission denied, mkdir '/opt/mixly_server/mixio-app/store'
       at init (/opt/mixly_server/mixio-app/mixio.js:923:12)
   ```

3. **NW 壳 / 窗口层故障：进程只活 2~3 秒**（v2.1.0 定位根因，v2.2.0 起默认避开）。这是 1、2 都修好之后暴露出来的下一层。日志特征与 1、2 **明显不同**：

   ```
   16:06:40  正在启动 MixlyServer
   16:06:41~42  大量 dbus 噪音 + XGetWindowAttributes failed for window 0
   16:06:43  MixlyServer 进程已退出，退出码: 0（本次存活 3s）
   ```

   关键判据：**存活只有几秒**（1、2 是约 120 秒），且 `runtime/nw-main-error.log` **没有新内容**——说明 `mixio.js` 已加载成功、`init()` 也通过了，故障不在 MixIO 初始化，而在 NW 壳。`XGetWindowAttributes failed for window 0` 里的 **window 0** 表示窗口句柄为空，即窗口从未真正创建成功、随后被销毁；NW.js 的默认行为是「所有窗口关闭即退出」，于是得到退出码 0。

   **根因（v2.1.0 实测确认）**：官方 `MixlyServer` 启动器 fork 出 `.host/nw` 时传了 `--ozone-platform=x11 --ozone-platform-hint=x11`。Chromium 的 ozone/X11 后端在 Xvfb 下连**隐藏窗口**（官方 `package.json` 主窗口 `show: false`）都创建失败，窗口句柄为 0 → 所有窗口被关闭 → NW.js 以退出码 0 结束，全程约 3 秒。注意此时 **MixIO 各服务其实已经就绪**（8443 端口探针有响应、`Database Connected!` 已打印），死的只是窗口层。同一环境、同一运行包，**不指定 ozone**（Chromium 自动探测 X11）时完全正常：1883/8082-8086/8443/18084 全部监听，容器长期存活——v2.2.0 起这就是默认启动方式。

   已实测**证伪**的几个猜测，列出来避免重复走弯路：

   | 猜测 | 证伪依据 |
   |---|---|
   | 残留 PID 误杀 Xvfb | `pid.info` 内容为 203，而该次容器内最高 PID 仅 146，`kill` 只会得到 ESRCH；且 Xvfb 全程存活、无被杀记录 |
   | `/dev/shm` 不足 | 那会得到退出码 **139（SIGSEGV）**，不是 0 |
   | 证书问题 | `package.json` 的 `chromium-args` 已含 `--ignore-certificate-errors` |
   | 端口冲突触发 `Continue? [y/N]` | 启动前端口快照显示 8443/18084 等均空闲 |
   | dbus 报错（`Could not parse server address`） | 容器内无 dbus daemon，libdbus 经 X11 autolaunch 读不到根窗口属性必报此错；Chromium 社区（Gentoo bug 879837）已证实它与进程退出无关 |

   v2.0.8 起入口脚本会打印 `本次存活 Ns` 并按此时长自动分流诊断；**v2.1.0 起全自动取证 + 策略轮换，v2.2.0 起把实测可用的「直连无 ozone」提为默认策略（见下节），不需要执行任何命令**。

4. **官方启动器自身的可观测性缺陷**（v2.0.9 新增旁路模式）。`MixlyServer` 是 `fork` + `execv` 的壳，父进程负责打印 `Checking ports` / `Port conflict detected` / `Starting NW runtime` / `Loading MixIO service` 等进度——但**父进程的 stdout 在管道下是全缓冲的**，容器非 TTY 时这些消息会随缓冲区一起丢失。所以「日志里看不到启动器进度」是正常的，不代表没执行；反之，一旦启动器真的在 `Checking ports` 阶段退出，你同样看不到任何原因。它还有 `Continue? [y/N]` 交互询问，非 TTY 下读 stdin 立即 EOF。

**v2.0.6 / v2.0.7 / v2.0.8 起镜像已分别覆盖前两条路径，多数情况下升级镜像即可正常启动：**

```bash
# 1) 换成新镜像（注意：docker run / compose up 不会自动拉新版 latest）
docker pull ghcr.io/realkiro/mixly-server:latest
docker rm -f <容器名>
docker run -d --name <容器名> --restart unless-stopped --shm-size=1g \
  -p 8443:8443 -p 18084:18084 -p 1883:1883 -p 8083:8083 -p 8084:8084 -p 8082:8082 -p 8086:8086 \
  -v /你的路径/mixly_server:/opt/mixly_server \
  ghcr.io/realkiro/mixly-server:latest

# 2) 确认这两类行出现（说明 v2.0.8 真的跑起来了）
docker logs <容器名> 2>&1 | grep -E "已预置|已清理残留 PID 文件"
```

### 第 3 条路径：v2.1.0 起全自动取证 + 策略轮换（v2.2.0 起根因已避开）

**v2.2.0 起，上面路径 3 的根因（官方启动器的 `--ozone-platform=x11` 在 Xvfb 下建不了窗口）已在默认启动方式中避开**——入口脚本默认直连 `.host/nw` 且不指定 ozone，让 Chromium 自动探测 X11。绝大多数部署升级后直接正常，不需要任何操作。

万一你的环境不同（例如真实 X 服务器、或将来官方改了参数），自动兜底依然在：每次「短命-0」失败时，入口脚本会自动打印一段 `自动取证开始 … 自动取证结束` 的日志：

| 取证项 | 回答的问题 |
|---|---|
| 8443 端口探针（1s 间隔，启动即开始） | MixIO 服务到底起没起来过？起来了 = 窗口/渲染层问题；从未起来 = 初始化问题 |
| `mixio-app/logs` 末 15 行 | MixIO 自己卡在哪一步 |
| `runtime/nw-main-error.log` | `mixio.js` 顶层加载是否失败（空 = 已加载成功，故障在 NW 壳） |
| 进程列表 + Xvfb 存活状态 | Xvfb 是否被误杀 |
| `xdpyinfo`（X 服务器 visual 与扩展） | 窗口建失败时最常见的环境根因（如缺 ARGB visual / RANDR / DAMAGE） |
| NW.js 最小窗口自检（双探针：无 ozone 主探针 + ozone 对照探针） | 一刀区分「镜像环境问题」与「MixSuite 应用层问题」；两探针结果不同即直接复现根因 |

同时，**重启循环本身变成 A/B 实验**：连续短命失败时，每次重启自动切换一种启动方式，日志里每次都会打印 `启动策略 N/4`：

| 策略 | 启动方式 | 验证的假设 |
|---|---|---|
| 1 | 直连 `.host/nw`，**不指定 ozone**，让 Chromium 自动探测 X11（**默认**，v2.1.0 实测稳定） | 基线；v2.2.0 起每次重启都从它开始 |
| 2 | 官方启动器（经 `stdbuf` 强制行缓冲，启动器自己的 `Checking ports` / `Port conflict detected` / `MixlyServer exited before becoming ready` 等进度不再丢失） | 官方路径；同时补上启动器层的可观测性 |
| 3 | 直连 `.host/nw`，强制 ozone x11（与官方参数一致）+ Chromium 内部日志 | 与 1 对照，隔离 ozone 因素（v2.1.0 已证实这是根因） |
| 4 | 直连 `.host/nw`，关闭原生窗口遮挡检测（`--disable-features=CalculateNativeWinOcclusion`） | 无窗口管理器环境下，遮挡检测是否干扰窗口生命周期 |

轮换规则：**只有「进程自己短命-0 退出」才推进策略**；`docker stop`、崩溃、超时退出都会把计数重置，下次仍从默认策略 1 开始。计数文件在挂载卷的 `mixio-app/runtime/boot-attempt` 里，想固定某种方式就手写这个数字（1~4）；也可以用环境变量 `MIXLY_STRATEGY=1~4` 显式固定（优先级高于计数器，固定期间不读写计数器，非法值自动忽略并回退计数器逻辑）。

**你要做的只有一件事：把 `自动取证开始` 到 `自动取证结束` 之间的完整日志反馈。**

#### 仍然可用的手动诊断开关（v2.0.9+）

如果希望主动控制而不是等自动轮换，两个开关依然有效（设置后不参与策略轮换）：

**① `MIXLY_NW_SELFTEST=1` —— 只做最小窗口自检然后退出**

用一个最小 NW 应用（临时 `package.json` + `index.html`）测本容器能否创建窗口并加载页面：

```bash
docker run --rm -e MIXLY_NW_SELFTEST=1 \
  -v /你的路径/mixly_server:/opt/mixly_server \
  ghcr.io/realkiro/mixly-server:latest
```

- `✅ 通过`（探针 A，无 ozone）→ 镜像依赖齐备，问题在 MixSuite 应用层 → 用开关 ② 继续
- `❌ 失败`（探针 A）→ NW.js/Chromium 在本容器建不了窗口，属镜像依赖问题 → 把完整日志（含 `xdpyinfo` 输出）反馈，以便补依赖
- 探针 B（ozone 对照）失败而探针 A 通过 → 即复现 v2.1.0 定位的根因：`--ozone-platform=x11` 在 Xvfb 下导致窗口创建失败（window 0）

**② `MIXLY_DIRECT_NW=1` —— 固定走直连模式，打开 Chromium 内部日志**

直接 `exec .host/nw`（参数与官方启动器一致），并追加 `--enable-logging=stderr`，把 Chromium 的窗口创建、GPU 进程、渲染进程等内部状态全部打出来：

```bash
docker run -d --name mixly-diag -e MIXLY_DIRECT_NW=1 --restart unless-stopped --shm-size=1g \
  -p 8443:8443 -p 18084:18084 \
  -v /你的路径/mixly_server:/opt/mixly_server \
  ghcr.io/realkiro/mixly-server:latest

docker logs mixly-diag 2>&1 | tail -80
```

日志里会明确出现窗口为何创建失败（缺 X11 扩展、widget 未初始化等）。

> 两个开关都是**诊断用**。注意 v2.2.0 起默认启动方式本来就是直连 `.host/nw`（无 ozone），`MIXLY_DIRECT_NW=1` 与它的差别只是固定使用官方那套 ozone 参数 + 内部日志，用于复现和对照；想回到官方启动器路径，用策略轮换里的策略 2（把 `mixio-app/runtime/boot-attempt` 手写为 `1`，下次重启即走官方启动器）。

如果升级后仍反复重启，v2.0.6 起 `runtime/nw-main-error.log` 会被自动打印到 `docker logs`，先看它：

```bash
# A) mixio.js 加载失败时，nw-main.js 会把完整堆栈写到这里（已自动打印，这里可复查）
docker exec <容器名> sh -c 'cat /opt/mixly_server/mixio-app/runtime/nw-main-error.log'

# B) mixio-app 目录本身的权限（mixly 需能在其下新建目录，权限位应含 rwx）
docker exec <容器名> sh -c 'ls -ld /opt/mixly_server/mixio-app /opt/mixly_server/mixio-app/store'

# C) 端口到底有没有起来
docker exec <容器名> sh -c 'netstat -lntp | grep -E "8443|18084"'
```

错误内容按类型分流：

| nw-main-error.log 关键字 | 含义 | 处理 |
|---|---|---|
| `EACCES: permission denied, mkdir` | 文件权限问题，`mixio-app` 对 mixly 不可写 | 宿主机执行 `chmod -R a+rwX <mixio-app 所在目录>`；挂载来源若是 NFS/CIFS/Windows 共享，改成本地目录或 ext4 |
| `Cannot find module 'node:sqlite'` | NW.js 内置 Node 版本过旧，不支持 `node:sqlite` | 属于官方包问题，请把完整日志反馈给米思奇官方 |

v2.0.6 / v2.0.7 起入口脚本会自动完成以下动作，不必再手工取证：

- 预置 `storage/reserve/filter.json`（缺失或非法时自动修正为 `{}`）
- 预建 `mixio-app/store`、`mixio-app/config/certs`，并对 `mixio-app` 目录本身 `chmod a+rwX`
- 启动前实测 mixly 对 `user-data`、`mixio-app`、`storage/reserve` 三处的写入能力，失败即明确报错退出
- 主动捕获并打印 `runtime/nw-main-error.log` 的完整内容，并按错误类型分流诊断
- 把上一次残留的 `nw-main-error.log` 轮换为 `.prev`，避免旧错误被反复误读为新故障
- 退出码 0 时打印 `本次存活 Ns` 并按存活时长分流：**<15s 指向窗口层，≥15s 才指向就绪探测超时**
- 启动前输出端口监听快照与进程列表，便于判断 18084 是否真被占

v2.1.0 起额外自动完成（窗口层故障场景，**无需手动执行任何命令**）：

- 启动时开始 1s 间隔的 8443 端口探针，记录服务首次响应时刻
- 短命-0 退出时自动执行取证：端口探针结果、`logs` 末 15 行、`nw-main-error.log`、进程与 Xvfb 状态、`xdpyinfo`（X 服务器 visual/扩展）、NW.js 最小窗口自检
- 经 `stdbuf` 强制行缓冲启动官方启动器，其 `Checking ports` / `Port conflict detected` / `MixlyServer exited before becoming ready` 等进度不再因全缓冲丢失
- 重启循环自动轮换 4 种启动方式，计数存于 `mixio-app/runtime/boot-attempt`；`docker stop` 等正常退出自动重置

v2.3.0 起额外自动完成（MixMO 场景，**无需手动执行任何命令**）：

- 每次启动幂等 patch 卷内 `mixio.js`：补 `/mixmo` 静态挂载（官方 10-15 包内置 `mixmo/` 但服务端未挂载）与首页入口参数；首次 patch 前备份 `mixio.js.mixly-docker-orig`，官方在线更新覆盖后自动重打
- 卷内无 `mixmo/` 时 `/mixmo` 自然 404、不显示首页入口；放入 `mixmo/` 后无需重启即生效

v2.2.0 起（根因已定位后的收尾）：

- **默认启动方式改为直连 `.host/nw` 且不指定 ozone**（Chromium 自动探测 X11）——官方启动器的 `--ozone-platform=x11` 在 Xvfb 下会导致窗口创建失败（window 0 → 约 3 秒退出码 0），这是「只活几秒」故障的根因；v2.1.0 用户日志实测：避开该参数后 MixIO 全服务就绪、容器长期稳定
- 最小窗口自检改为双探针：探针 A 用默认参数（无 ozone）判定「本容器能否建窗口」，探针 B 补回官方 ozone 参数做对照，两探针结果不同即直接复现根因
- 策略轮换顺序调整为 1 直连无 ozone（默认）→ 2 官方启动器 → 3 直连强制 ozone → 4 直连关闭遮挡检测；连续失败时才逐级回退，`docker stop` 后重置

> **注意**：`docker run` / `docker compose up` 在本地已存在同名 `latest` tag 时**不会**拉取新镜像。升级必须 `docker pull`（compose 用 `docker compose pull`）后**删除旧容器再启动**，否则跑的仍是旧版——旧版与新版的日志文案不同，可用 `docker logs | grep 已预置` 判断当前到底跑的是哪一版。

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

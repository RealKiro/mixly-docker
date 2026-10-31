# Mixly 4.0（MixSuite）离线服务端 Docker 适配（群晖 NAS / Debian 轻镜像）

## 方案说明

**镜像只包含运行环境，不含官方运行包。** 使用者需从官方百度网盘下载 `MixSuite-linux-<架构>.zip`，解压后放入容器的映射路径；首次启动若未检测到运行包，容器会打印放置指引后退出。

### MixSuite 是什么（与旧版 mixly_server 的区别）

Mixly 4.0 起官方只有一个发行版：**内置 MixIO 的 MixSuite**（`MixlyServer`）。它是 NW.js（Chromium 107 + Node）桌面应用，而不是旧版那样的 Node/pkg 单文件 CLI：

```
MixSuite-linux-x64/
├── MixlyServer          # 启动器（ELF）：读 MIXIO_*_PORT 环境变量写 config，
│                        # 然后 exec .host/nw --no-sandbox --disable-gpu
│                        # --user-data-dir=<套件根>/user-data mixio-app
├── .host/               # NW.js 运行时（nw 加载器 + lib/libnw.so 305MB + libnode.so）
├── mixio-app/           # NW 应用：nw-main.js 以【同进程】require mixio.js
│                        #   → MixIO 服务直接跑在 NW 进程里
│   ├── config/          #   config.json（端口/管理员/证书路径）+ certs/ 自签证书
│   ├── storage/         #   SQLite 数据（mixio.db、reserve/*.db、drive 上传文件）
│   ├── logs/            #   日志（同时输出 stdout，docker logs 可见）
│   └── runtime/         #   运行时目录
├── mixly/               # Mixly 编辑器静态资源（服务以 /mixly 托管）
├── mixco/               # 课程静态资源（loong64 包无此目录，可选）
└── mixmo/               # MixMO 静态资源（2026-10-15 起官方包内置；v2.3.0 镜像自动补 /mixmo 路由）
```

由此带来的关键行为变化：

- **前台运行，不 daemon 化**：旧版 `mixio start` 会 fork 后台进程然后父进程退出，导致容器"起来又停"；MixSuite 版 MixlyServer 前台运行、自行处理 SIGTERM/SIGINT 优雅退出，入口脚本直接 `exec`，不再需要守护循环。
- **强制 HTTPS-only**：`nw-main.js` 每次启动都会把 `config.json` 的 `MIXIO_HTTP_PORT` 改写为 `0`，HTTP(8080) 无法开启；默认 HTTPS 端口 8443（可用 `MIXIO_HTTPS_PORT` 环境变量覆盖，启动器负责写入 config）。
- **数据目录从 `mixio/` 变为 `mixio-app/`**：SQLite 在 `mixio-app/storage/`，日志在 `mixio-app/logs/`，配置/证书在 `mixio-app/config/`。官方迁移方式是复制 `storage` 文件夹——由于运行包整体挂载在宿主机目录，升级镜像天然不丢数据。
- **端口**（`mixio-app/config/config.json`）：HTTPS 8443、管理 18084（硬编码）、MQTT 1883、WS 8083、WSS 8084、Yjs 8082、Yjs-WSS 8086、NTP 123/UDP（非特权用户绑定失败仅告警，不致命；需要 NTP 仿真时加 `cap_add: NET_BIND_SERVICE`）。
- **NW.js 需要 X11**：容器内用 Xvfb 提供虚拟显示（`:99`，1280x800x24）。服务端部署下浏览器访问不依赖它，GUI 壳仅作本地运维兜底。

### 为什么基础镜像是 Debian 而不是 Alpine

旧版 `mixio` 是普通 glibc 动态链接 ELF，Alpine + gcompat 能跑；但 MixSuite 的 `.host/lib/libnw.so` 是完整的 Chromium 构建，对 glibc 的依赖（IFUNC/TLS/线程语义等）远超 gcompat 的兼容范围，musl 下 renderer 进程极易崩溃。因此改用 **Debian trixie-slim**（NW.js 官方就是按 Debian 系构建的），并安装 GTK3/NSS/X11/ALSA/fontconfig 等依赖 + Xvfb。

- amd64 / arm64：Docker Hub 官方 `debian:trixie-slim`
- loong64：Docker Hub 官方 debian 无 loong64 变体，用社区同步镜像 `ghcr.io/loong64/debian:trixie-slim`（与官方同源构建），按架构分别构建后用 manifest 合并。

镜像约 300MB（NW.js 运行时依赖 + Xvfb + 中文字体），运行包本身仍由使用者挂载提供。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | `debian:trixie-slim`（loong64 用 `ghcr.io/loong64/debian:trixie-slim`）+ NW.js/X11 依赖 + Xvfb + gosu + tini 的运行环境镜像（约 300MB，amd64+arm64+loong64 三架构） |
| `docker-entrypoint.sh` | 启动前定位 MixSuite 包、校验 `.host/nw` ELF 架构、预建并 chown `mixio-app` 数据目录、起 Xvfb 虚拟显示、gosu 降权后 `exec MixlyServer`（前台运行） |
| `docker-compose.yml` | 群晖 Container Manager 可直接导入，含端口（8443/18084/1883/8083/8084/8082/8086）、挂载、串口透传示例 |
| `build-push.sh` | 本地 buildx 构建并同时推送 GHCR + Docker Hub |
| `.github/workflows/ci.yml` | CI 流水线：PR/推 main 跑测试与跨架构构建检查；v* 标签或手动触发时测试通过后推送 GHCR + Docker Hub |
| `test/smoke-test.sh` | 冒烟测试：无需官方运行包，用假 MixSuite 包（ELF 桩 + 脚本桩）验证缺包指引/架构校验/Xvfb 启动/数据目录属主/前台保活/优雅退服/镜像元数据 |

## 首次运行（三步）

1. **建目录**：在群晖 File Station 建 `/docker/mixly/mixly_server`。
2. **放运行包**：从官方百度网盘下载对应架构的 `MixSuite-linux-<架构>.zip`（网盘地址与提取码请填这里：`＿＿＿＿＿＿`），解压后把**里面的全部内容**（`MixlyServer`、`.host/`、`mixio-app/`、`mixly/` 等）放进该目录。放好后应存在 `/docker/mixly/mixly_server/mixio-app/mixio.js`。
3. **启动容器**：Container Manager → 项目 → 新增 → 导入 `docker-compose.yml` → 启动。

启动成功后浏览器访问：

- `https://NAS_IP:8443` —— MixIO/Mixly 主界面（首页可进 Mixly / MixCO / MixMO / MixNT；自签证书点"高级 → 继续访问"）
- `https://NAS_IP:8443/mixmo` —— MixMO 手机 App 设计（需运行包含 `mixmo/` 的新版官方包，v2.3.0 起自动启用）
- `https://NAS_IP:18084` —— 管理模式（数据管理、用户导入、手动更新 Mixly/MixIO）

管理员默认 `admin/public`，**上线后务必修改** `mixio-app/config/config.json` 中的 `ADMIN_PASSWORD`；离线内网可保留 `ALLOW_REGISTER`。如需外网访问，在 DSM 控制面板做端口映射或用 DSM 反向代理套 443。

> 若容器反复重启且日志出现"未检测到 Mixly 官方运行包"，说明第 2 步的路径放错了——注意是把 `MixSuite-linux-x64` 文件夹**里面的内容**放到映射目录，而不是多套一层。入口脚本对多套一层有自动兼容（会打 WARN 并自动进入子目录），但仍建议放对。

## 构建并推送镜像（本地，推荐）

```bash
docker login ghcr.io          # 用户名为 GitHub 用户名，密码用 PAT(write:packages)
docker login                  # Docker Hub

GHCR_USER=RealKiro DOCKERHUB_USER=你的DockerHub用户名 ./build-push.sh v2.0
```

镜像约 300MB，输出 `linux/amd64` + `linux/arm64` + `linux/loong64` 三架构 manifest，x64 / ARM / 龙芯设备均可拉取。

## 架构说明

- 官方按机型提供 `MixSuite-linux-x64 / -arm64 / -loong64` 运行包，各架构包内启动文件同名 `MixlyServer`；不清楚自己机型的架构可咨询主机厂家。
- 三种架构设备都直接 `docker pull` 多架构镜像，放入对应架构的运行包即可运行。
- 入口脚本启动时解析运行包 `.host/nw` 二进制的 ELF 头（e_machine 字段）校验架构匹配：x64↔x64、aarch64↔arm64、loongarch64↔loong64；不匹配会明确提示应下载的架构并退出，无法识别时（如非 ELF 文件）仅警告并继续。

## 构建后验证

```bash
# 未挂载运行包时应打印放置指引并退出 —— 这本身就是入口脚本的自检
docker run --rm ghcr.io/realkiro/mixly-server:v2.0

# 挂载本地运行包做完整验证
docker run --rm -v "$(pwd)/mixly_server:/opt/mixly_server" -p 8443:8443 ghcr.io/realkiro/mixly-server:v2.0
# 预期日志: [INFO] NTP 服务器已启动 / MixIO 管理服务器已启动，端口: 18084 等；
# 浏览器打开 https://127.0.0.1:8443 应见 MixIO 界面（自签证书需继续访问）
```

或跑冒烟测试（无需官方运行包）：

```bash
bash test/smoke-test.sh ghcr.io/realkiro/mixly-server:v2.0
```

## 常见问题

- **想用 `https://域名/admin` 访问管理后台**：设置环境变量 `MIXIO_ADMIN_BASE=/admin`，反向代理把 `^/admin(/.*)?$`（cloudflared 的 `path` 是 Go 正则）转发到 18084（自签证书需关闭上游校验，cloudflared 用 `noTLSVerify: true`）。入口脚本会在启动时剥掉前缀、注入 `<base href="/admin/">` 并把管理端模板的根路径改成相对路径，同时改写首页“管理后台”链接；不设置时保持官方原行为。详见 [README.md](README.md#管理后台走-admin)。
- **`/admin` 里点“检查更新”立刻 404**（控制台报 `https://域名/api/download?url=…` 或 `/api/check-update` 404）：这两条是根路径，需要补丁相对化成 `api/download`、`api/check-update`（v2.4.3 起），v2.4.4 起还会在页面里注入运行时兜底脚本（改写 `fetch`/`XHR`/`EventSource` 的根路径 URL），不再依赖官方模板的具体写法；注入锚点带回退链（`<meta charset=…>` → `</head>` → `<head>` → 文件末尾，日志以 `锚点: …` 标明落点），官方调整头部写法也不会静默落空。镜像/脚本是旧版时更新入口脚本后重启容器即可；更新完成后因官方包会覆盖 `mixio.js` 与 `ejs/`，入口脚本的观察者会在 5 秒内自动重打，日志出现 `检测到运行包被在线更新覆盖` 即代表已自愈。
- **点“一键更新”后停在“正在解压…”并报 `EACCES: permission denied, mkdir '/opt/mixly_server/.mixio-app-stash'`（或 `.mixly-suite-stash`）**：官方更新流程以容器内 `mixly` 身份往**套件根目录**写暂存夹、把 `mixly/` 改名备份、就地覆盖 `mixio-app/` 内文件；而宿主机解压的官方包属主是宿主机用户、目录 755、文件 644，容器内没有写权限。本版起入口脚本在启动时按需补一次写权限（`chmod -R a+rwX`，**只改权限位、不改属主**，宿主机用户的管理权限不受影响），并用 `mixio-app/runtime/.suite-perms-ok` 戳文件避免每次启动都递归遍历（宿主机重新解压官方包后探针失败会自动重跑）。日志出现 `在线更新写权限已就绪` 即代表生效；旧镜像也可手动 `chmod -R a+rwX /volume1/docker/mixly/mixly_server` 后重启容器。
- **更新时出现 524（Cloudflare）**：`/api/download` 是 SSE 进度流，整包下载经隧道可能超过 Cloudflare 对源站的 100 秒超时。大版本更新建议在局域网直连 `https://NAS_IP:8443/admin`（或 `:18084`）操作，域名方式留给小更新。
- **只有 https 能访问，http 8080 打不开**：MixSuite 设计如此（每次启动强制把 HTTP 端口置 0），请用 `https://<ip>:8443`。
- **容器起来约几秒后 Mixly 界面才可用**：正常。NW 壳先起本地 HTTPS 服务，窗口就绪后才加载编辑器；`docker logs` 可看到启动过程。
- **18084 端口冲突导致管理服务起不来**：容器内一般不会遇到；日志出现 `端口 18084 仍被占用` 时检查是否有同机其他 MixIO 实例。
- **NTP 仿真不可用**：非 root 无法绑定 UDP 123，仅告警不致命；需要时在 compose 加 `cap_add: [NET_BIND_SERVICE]` 并映射 `123:123/udp`。
- **烧录时找不到串口**：透传 USB 设备并加 `group_add: [dialout]`，见 [README.md](README.md) 的「烧录硬件」一节。
- **想看看容器里那个 GUI 窗口**：它在 Xvfb 虚拟显示里，浏览器访问无需它；确有需要可 `docker exec -it <容器> bash` 后自行安装 `x11vnc`/`xterm` 等工具。
- **容器反复重启、只活几秒、日志有 `XGetWindowAttributes failed for window 0`**：这是 NW.js 窗口层故障（窗口从未创建成功）。v2.1.0 已定位根因——官方启动器传给 `.host/nw` 的 `--ozone-platform=x11` 在 Xvfb 下建不了窗口；**v2.2.0 起默认启动方式已避开该参数（直连 `.host/nw`，不指定 ozone）**，升级后即恢复正常。详见下节[排障存档](#排障存档短命-0-退出与启动策略轮换)。
- **MixMO（手机 App 设计）怎么进**：官方 MixSuite 2026-10-15 起的压缩包已内置 `mixmo/`（与 `mixly/`、`mixco/` 同级，解压即用；MixlyAI 包较大，需单独下载解压后放入套件根目录）。该版本官方桌面壳菜单和管理端已接入 MixMO，但服务端 `mixio.js` 还没挂 `/mixmo` 路由——**本镜像 v2.3.0 起入口脚本会自动给卷内 `mixio.js` 打幂等补丁**（首次前备份 `mixio.js.mixly-docker-orig`；官方在线更新覆盖后自动重打），补上 `/mixmo` 静态挂载和首页入口，直接访问 `https://<IP>:8443/mixmo` 即可。详见 [README.md](README.md#升级-mixsuite-运行包保留数据)。

## 排障存档：短命-0 退出与启动策略轮换

> 这是开发期定位「容器反复重启、退出码 0、日志空白」时留下的完整链路。**v2.2.0 起默认启动方式已避开根因**，正常情况下无需阅读本节；仅在升级后仍复现、或需要向维护者反馈时使用。

### 故障为何不可见

`MixlyServer` 是 `fork` + `execv` 的壳：父进程负责打印 `Checking ports` / `Starting NW runtime` 等进度，但**父进程 stdout 在管道下是全缓冲**，容器非 TTY 时这些消息随缓冲区一起丢失。同时 `mixio.js` 顶层 `daemon_start().then(...)` 没有 `.catch`、`JSON.parse(fs.readFileSync(filterPath))` 没有 try/catch，异常被吞后外壳继续探测 8443，60 秒（120×500ms）后放弃并以**退出码 0** 结束——于是 `docker logs` 里什么真实原因都看不到。

### 三层触发路径与现状

| # | 触发点 | 症状 | 处理 |
|---|---|---|---|
| 1 | `storage` 目录存在但缺 `reserve/filter.json`（官方只在 `storage` 不存在时才创建它） | 约 120 秒后退出码 0 | v2.0.6 起入口脚本预置并校验 `filter.json` |
| 2 | `mixio-app` 目录对 mixly 用户不可写（`store`/`logs`/`config` 建不出来） | 约 120 秒后退出码 0，或 `EACCES: mkdir` | v2.0.7 起预建目录并 `chmod a+rwX`；virtiofs/NFS 上 `chown` 无效是根因 |
| 3 | NW 窗口层：官方启动器的 `--ozone-platform=x11` 在 Xvfb 下建不了窗口（`window 0`） | **只活 2~3 秒**、退出码 0、`nw-main-error.log` 无新内容 | v2.2.0 起默认直连 `.host/nw` 且不指定 ozone |

判据：**存活 <15 秒指向窗口层（路径 3），≥15 秒才指向就绪探测超时（路径 1/2）**。

曾被实证证伪的猜测（避免重复走弯路）：残留 PID 误杀 Xvfb、`/dev/shm` 不足（那是退出码 139 SIGSEGV）、证书问题（`package.json` 已含 `--ignore-certificate-errors`）、端口冲突触发 `Continue? [y/N]`、dbus 报错。

### 自动取证与策略轮换

连续「短命-0」失败时，入口脚本会打印 `自动取证开始 … 自动取证结束`，内容包含：8443 端口探针（1s 间隔，启动即开始）、`mixio-app/logs` 末 15 行、`runtime/nw-main-error.log`、进程与 Xvfb 状态、`xdpyinfo`（X visual/扩展）、NW.js 最小窗口自检（无 ozone 主探针 + ozone 对照探针）。

同时重启循环本身变成 A/B 实验，每次失败切换一种启动方式，日志打印 `启动策略 N/4`：

| 策略 | 启动方式 | 验证的假设 |
|---|---|---|
| 1 | 直连 `.host/nw`，**不指定 ozone**（**默认**） | 基线 |
| 2 | 官方启动器（经 `stdbuf` 强制行缓冲，进度不再丢失） | 官方路径 |
| 3 | 直连 + 强制 ozone x11 | 隔离 ozone 因素（已证实是根因） |
| 4 | 直连 + `--disable-features=CalculateNativeWinOcclusion` | 无窗口管理器时遮挡检测是否干扰 |

只有「进程自己短命-0 退出」才推进策略；`docker stop`、崩溃、超时都会重置计数。计数在挂载卷的 `mixio-app/runtime/boot-attempt`（1~4），也可用环境变量 `MIXLY_STRATEGY=1~4` 显式固定（优先级更高）。

### 手动诊断开关

| 变量 | 作用 |
|---|---|
| `MIXLY_NW_SELFTEST=1` | 仅用最小 NW 应用测「本容器能否建窗口」，然后退出。探针 A（无 ozone）通过 = 镜像依赖齐备、问题在应用层；A 失败 = 镜像/环境问题，反馈完整日志（含 `xdpyinfo`） |
| `MIXLY_DIRECT_NW=1` | 固定直连 `.host/nw` 并追加 `--enable-logging=stderr`，把 Chromium 的窗口创建、GPU 与渲染进程状态全打出来 |

```bash
docker run --rm -e MIXLY_NW_SELFTEST=1 \
  -v /你的路径/mixly_server:/opt/mixly_server \
  ghcr.io/realkiro/mixly-server:latest
```

### `nw-main-error.log` 判读

入口脚本会把该文件内容自动打印到 `docker logs`，并把上一次的轮换为 `.prev`（避免旧错误被误读为新故障）。按关键字分流：

| 关键字 | 含义 | 处理 |
|---|---|---|
| `EACCES: permission denied, mkdir` | `mixio-app` 对 mixly 不可写 | 宿主机 `chmod -R a+rwX <mixio-app 所在目录>`；挂载源若是 NFS/CIFS/Windows 共享，改本地 ext4 目录 |
| `Cannot find module 'node:sqlite'` | NW.js 内置 Node 版本过旧 | 属官方包问题，反馈给米思奇官方 |

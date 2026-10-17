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
└── mixmo/               # MixMO 静态资源（可选）
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

- `https://NAS_IP:8443` —— MixIO/Mixly 主界面（左下角可进 Mixly / MixMO；自签证书点"高级 → 继续访问"）
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

- **只有 https 能访问，http 8080 打不开**：MixSuite 设计如此（每次启动强制把 HTTP 端口置 0），请用 `https://<ip>:8443`。
- **容器起来约几秒后 Mixly 界面才可用**：正常。NW 壳先起本地 HTTPS 服务，窗口就绪后才加载编辑器；`docker logs` 可看到启动过程。
- **18084 端口冲突导致管理服务起不来**：容器内一般不会遇到；日志出现 `端口 18084 仍被占用` 时检查是否有同机其他 MixIO 实例。
- **NTP 仿真不可用**：非 root 无法绑定 UDP 123，仅告警不致命；需要时在 compose 加 `cap_add: [NET_BIND_SERVICE]` 并映射 `123:123/udp`。
- **烧录时找不到串口**：透传 USB 设备并加 `group_add: [dialout]`，见 [README.md](README.md) 的「烧录硬件」一节。
- **想看看容器里那个 GUI 窗口**：它在 Xvfb 虚拟显示里，浏览器访问无需它；确有需要可 `docker exec -it <容器> bash` 后自行安装 `x11vnc`/`xterm` 等工具。
- **容器反复重启、只活几秒、日志有 `XGetWindowAttributes failed for window 0`**：这是 NW.js 窗口层故障（窗口从未创建成功）。v2.1.0 已定位根因——官方启动器传给 `.host/nw` 的 `--ozone-platform=x11` 在 Xvfb 下建不了窗口；**v2.2.0 起默认启动方式已避开该参数（直连 `.host/nw`，不指定 ozone）**，升级后即恢复正常。万一环境不同，重启循环会自动取证（端口探针 / MixIO 日志 / xdpyinfo / 双探针窗口自检）并轮换 4 种启动方式，把 `自动取证开始` 到 `自动取证结束` 之间的日志反馈即可，详见 [README.md](README.md) 的 Q11。

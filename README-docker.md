# Mixly 离线服务端 Docker 适配（群晖 NAS / Alpine 轻镜像）

## 方案说明

**镜像只包含运行环境，不含官方运行包。** 使用者需从官方百度网盘下载 `mixly_server` 压缩包，解压后放入容器的映射路径；首次启动若未检测到运行包，容器会打印放置指引后退出。

- 官方三个压缩包中，只有 `mixly_server`（mixio + mixly + mixco，约 2.7GB）是服务端；`mixly4-linux-x64.zip` 和 `MixAI-linux-x64.zip` 是 NW.js **桌面版**，不适用于服务器部署。
- `mixio` 是用 Node.js 16.17.0（pkg）打包的**glibc 动态链接 x86-64 ELF**（145MB），需要 GLIBC ≥ 2.17、libstdc++、libgcc。官方指令为 `mixio start / stop / install / help`（默认 HTTP 8080，HTTPS 8443，管理模式 18084），见 [gitee.com/mixly2/mixio](https://gitee.com/mixly2/mixio)。它同时是 Web、MQTT(1883)、WebSocket(8083/8084)、Yjs 协同(8082/8086) 服务，并托管 `../mixly`（编辑器）与 `../mixco`（课程）静态资源。
- 数据落盘：SQLite 在 `mixio/storage/`，项目文件在 `mixio/store/`，日志在 `mixio/logs/`，配置/证书在 `mixio/config/`。**官方迁移方式是复制 `storage/reserve` 文件夹**——由于运行包整体挂载在宿主机目录，升级镜像天然不丢数据。

### 为什么 Alpine 还能跑 glibc 程序

Alpine 基础镜像仅 ~8MB，加 `gcompat`（glibc→musl 兼容层）+ `libstdc++` + `libgcc` 后可运行多数 glibc 二进制。**首次构建后务必验证**（见下），如 gcompat 不兼容再改用 `debian:bookworm-slim` 备选（镜像约 +60MB）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | Alpine 3.20 + gcompat + su-exec + tini 的运行环境镜像（约 15MB） |
| `docker-entrypoint.sh` | 启动前检测运行包、提示放置路径、修正执行权限、以非 root 运行 |
| `docker-compose.yml` | 群晖 Container Manager 可直接导入，含端口与挂载 |
| `build-push.sh` | 本地 buildx 构建并同时推送 GHCR + Docker Hub |
| `.github/workflows/docker-publish.yml` | 可选 CI 自动构建（轻镜像可直接进仓库，无大文件问题） |

## 首次运行（三步）

1. **建目录**：在群晖 File Station 建 `/docker/mixly/mixly_server`。
2. **放运行包**：从官方百度网盘下载 `mixly_server` 压缩包（网盘地址与提取码请填这里：`＿＿＿＿＿＿`），解压后把内容 `mixio/`、`mixly/`、`mixco/` 三个文件夹放进该目录。放好后应存在 `/docker/mixly/mixly_server/mixio/mixio`。
3. **启动容器**：Container Manager → 项目 → 新增 → 导入 `docker-compose.yml` → 启动。

启动成功后浏览器访问：

- `http://NAS_IP:8080` 或 `https://NAS_IP:8443` —— MixIO 主界面（左下角可进 Mixly / MixAI）
- `https://NAS_IP:18084` —— 管理模式（数据管理、用户导入、手动更新 Mixly/MixIO；Mixly 更新实时生效，MixIO 更新需重启容器）

管理员默认 `admin/public`，**上线后务必修改** `config.json` 中的 `ADMIN_PASSWORD`；离线内网可保留 `ALLOW_REGISTER`。如需外网访问，在 DSM 控制面板做端口映射或用 DSM 反向代理套 443。

> 若容器反复重启且日志出现"未检测到 Mixly 官方运行包"，说明第 2 步的路径放错了——注意是把 `mixly_server` 文件夹**里面的内容**放到映射目录，而不是多套一层 `mixly_server/mixly_server`。

## 构建并推送镜像（本地，推荐）

```bash
docker login ghcr.io          # 用户名为 GitHub 用户名，密码用 PAT(write:packages)
docker login                  # Docker Hub

GHCR_USER=RealKiro DOCKERHUB_USER=你的DockerHub用户名 ./build-push.sh v1.0
```

镜像约 15MB，构建几秒完成。官方二进制只有 x86-64 版本，因此仅构建 `linux/amd64`；群晖主流型号（Intel/AMD CPU）可运行，**ARM 型号（如 DS223j）不行**。

> ARM 支持提示：官方在 gitee 发行了 `mixio-linux-arm64-dist`（[发行页](https://gitee.com/mixly2/mixio/releases)），静态资源（mixly/mixco）与架构无关。如需支持 ARM 群晖，可按架构构建两个镜像变体（分别用对应架构的 mixio 二进制做健康检查），或维持 amd64 单架构。

## 构建后验证（gcompat 兼容性）

```bash
# 未挂载运行包时应打印放置指引并退出 —— 这本身就是入口脚本的自检
docker run --rm ghcr.io/RealKiro/mixly-server:v1.0

# 挂载本地运行包做完整验证
docker run --rm -v "$(pwd)/mixly_server:/opt/mixly_server" -p 8080:8080 ghcr.io/RealKiro/mixly-server:v1.0
# 预期日志: [INFO] MixIO server listening on port 8080 / Storage Engine: SQLite
```

若挂载运行包后报 `Illegal instruction` 或符号缺失（gcompat 偶发不兼容），把 Dockerfile 首行基础镜像换成 `debian:bookworm-slim`（其余逻辑不变，`adduser` 段改为 `useradd`，`su-exec` 改 `gosu`），镜像约 +60MB。

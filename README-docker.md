# Mixly 离线服务端 Docker 适配（群晖 NAS / Alpine）

## 分析结论

- 官方三个压缩包中，只有 `mixly_server`（mixio + mixly + mixco，约 2.7GB）是服务端；`mixly4-linux-x64.zip` 和 `MixAI-linux-x64.zip` 是 NW.js **桌面版**，不适合放进容器，已排除。
- `mixio` 是用 Node.js 16.17.0（pkg）打包的**glibc 动态链接 x86-64 ELF**（145MB），需要 GLIBC ≥ 2.17、libstdc++、libgcc。官方指令为 `mixio start / stop / install / help`（默认 HTTP 8080，HTTPS 8443），见 [gitee.com/mixly2/mixio](https://gitee.com/mixly2/mixio)。它同时是 Web、MQTT(1883)、WebSocket(8083/8084)、Yjs 协同(8082/8086) 服务，并托管 `../mixly`（编辑器）与 `../mixco`（课程）静态资源。
- 数据落盘：SQLite 在 `mixio/storage/`，项目文件在 `mixio/store/`，日志在 `mixio/logs/`，配置/证书在 `mixio/config/`。**官方迁移方式是复制 `storage/reserve` 文件夹**，升级镜像时保留 `storage/` 卷即可。

### 为什么 Alpine 还能跑 glibc 程序

Alpine 基础镜像仅 ~8MB，加 `gcompat`（glibc→musl 兼容层）+ `libstdc++` + `libgcc` 后可运行多数 glibc 二进制。**首次构建后务必验证**（见下），如 gcompat 不兼容再改用 `debian:bookworm-slim` 备选（镜像约 +60MB）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | Alpine 3.20 + gcompat，非 root 运行，tini 转发信号 |
| `.dockerignore` | 排除旧日志/数据库/pid 文件 |
| `docker-compose.yml` | 群晖 Container Manager 可直接导入，含端口与持久化卷 |
| `build-push.sh` | 本地 buildx 构建并同时推送 GHCR + Docker Hub |
| `.github/workflows/docker-publish.yml` | 可选 CI 自动构建（注意 mixio 二进制 145MB 超 GitHub 100MB 限制，需 Git LFS 或 CI 内下载源包） |

## 构建并推送（本地，推荐）

```bash
docker login ghcr.io          # 用户名为 GitHub 用户名，密码用 PAT(write:packages)
docker login                  # Docker Hub

GHCR_USER=你的GitHub用户名 DOCKERHUB_USER=你的DockerHub用户名 ./build-push.sh v1.0
```

官方二进制只有 x86-64 版本，因此仅构建 `linux/amd64`；群晖主流型号（Intel/AMD CPU）可运行，**ARM 型号（如 DS223j）不行**。

> ARM 支持提示：官方在 gitee 发行了 `mixio-linux-arm64-dist`（[发行页](https://gitee.com/mixly2/mixio/releases)），静态资源（mixly/mixco）与架构无关。如需支持 ARM 群晖，可在 CI 或构建脚本中下载 arm64 版 `mixio` 二进制替换后，将 `--platform` 改为 `linux/amd64,linux/arm64` 构建多架构镜像。

## 群晖部署

1. 在 File Station 建目录 `/docker/mixly`，上传 `docker-compose.yml`，并建 `data/` 子目录，把 `mixio/config`（config.json + certs）放入 `data/config`。
2. Container Manager → 项目 → 新增 → 选择该 compose 文件 → 启动。镜像名先改成你推送好的镜像。
3. 浏览器访问 `http://NAS_IP:8080` 或 `https://NAS_IP:8443`（MixIO）。管理员默认 admin/public，**上线后务必修改** `config.json` 中的 `ADMIN_PASSWORD`，离线内网可保留 `ALLOW_REGISTER`。
4. 如需外网访问，在 DSM 控制面板做端口映射或用 DSM 反向代理套 443。

## 构建后验证（gcompat 兼容性）

```bash
docker run --rm ghcr.io/你的用户名/mixly-server:v1.0
# 预期日志: [INFO] MixIO server (HTTPS) listening on port 8443 / Storage Engine: SQLite
```

若报 `Illegal instruction` 或符号缺失（gcompat 偶发不兼容），把 Dockerfile 首行基础镜像换成：

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*
# 其余 COPY/USER/EXPOSE/CMD 不变（USER 语法通用，adduser 段删除）
```

镜像约 2.9GB（Alpine 方案约 2.8GB，大头是 2.7GB 的静态资源，基础镜像差异有限）。

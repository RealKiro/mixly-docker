# mixly-docker

适配 [Mixly 米思齐](https://mixly.cn) 离线服务端（mixly_server）的 Docker 运行环境，支持群晖 NAS 等 **amd64 / arm64** 设备。

**镜像只含运行环境（约 15MB，Alpine + gcompat），不含官方运行包。** 使用者自行从官方百度网盘下载 `mixly_server` 压缩包，解压后放入挂载目录，首次启动时容器会自动检测并给出放置指引。

> 详细技术说明与本地构建方法见 [README-docker.md](README-docker.md)。

## 推荐使用方式：Star + Fork，推送到你自己的 GHCR

本项目不提供公共镜像，推荐每个使用者通过 GitHub Actions 把镜像构建到**自己账号**的 GHCR 下，拉取速度快、版本可控，也不依赖他人的仓库可用性。

### 1️⃣ Star 本仓库

如果这个适配对你有帮助，请先点一个 ⭐ Star，这是对作者最直接的支持，也方便你以后找到它。

### 2️⃣ Fork 到你的账号

点击右上角 **Fork**，把仓库复制到你的 GitHub 账号下。

### 3️⃣ 在 Fork 仓库中启用并运行构建

1. 进入你 Fork 的仓库 → **Actions** 标签页 → 按提示点击 **I understand my workflows, go ahead and enable them** 启用工作流。
2. 左侧选择 **docker-publish** → **Run workflow** → 运行。
   （也可以打一个 `v1.0` 标签推送来触发：`git tag v1.0 && git push origin v1.0`）
3. 构建几分钟完成（含 arm64），成功后镜像为多架构 manifest，自动覆盖：

   ```
   ghcr.io/<你的GitHub用户名>/mixly-server:latest   # linux/amd64 + linux/arm64
   ```

   GHCR 登录使用 Actions 自带的 `GITHUB_TOKEN`，**无需配置任何 Secrets**。
   （可选：想同时推送到 Docker Hub，再在 Settings → Secrets and variables → Actions 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，未配置时自动跳过。）

### 4️⃣ 把 GHCR 包设为 Public（否则 NAS 拉取需要登录）

你的 GitHub 头像 → **Packages** → `mixly-server` → **Package settings** → **Change visibility** → Public。
（保持 Private 也可以，但 NAS 端需要先 `docker login ghcr.io`。）

### 5️⃣ 放置官方运行包并启动

1. **按你的机器架构**从官方百度网盘下载对应的 `mixly_server` 压缩包（x64 / arm64 / loong64，不清楚可咨询主机厂家），解压后把 **`mixio/`、`mixly/`、`mixco/` 三个文件夹**放进该目录。
   放好后应存在 `/docker/mixly/mixly_server/mixio/mixio`。
2. 下载本仓库的 [docker-compose.yml](docker-compose.yml) 放到 `/docker/mixly/`，把 `image:` 改为你自己的镜像：

   ```yaml
   image: ghcr.io/<你的GitHub用户名>/mixly-server:latest
   ```

3. Container Manager → 项目 → 新增 → 选择该 compose 文件 → 启动。

### 6️⃣ 访问

| 入口 | 地址 | 说明 |
|---|---|---|
| MixIO 主界面 | `http://NAS_IP:8080` 或 `https://NAS_IP:8443` | 左下角可进 Mixly / MixAI |
| 管理模式 | `https://NAS_IP:18084` | 数据管理、用户导入、手动更新 |
| MQTT | `NAS_IP:1883` | 设备接入 |
| WebSocket MQTT | `NAS_IP:8083 / 8084` | 明文 / 加密 |
| Yjs 协同 | `NAS_IP:8082 / 8086` | 明文 / 加密 |

管理员默认 `admin/public`，**上线后务必在 `mixio/config/config.json` 中修改 `ADMIN_PASSWORD`**。若容器反复重启并提示"未检测到运行包"，说明路径多套了一层 `mixly_server`，把文件夹**里面的内容**放到映射目录即可。

## 本地构建（不用 GitHub Actions）

```bash
docker login ghcr.io
GHCR_USER=你的GitHub用户名 ./build-push.sh v1.0
```

构建 `linux/amd64` + `linux/arm64` 双架构 manifest，`docker pull` 时按设备架构自动选择。

## 架构与兼容性说明

官方为不同机型提供对应的 `mixly_server` 压缩包（**x64 / arm64 / loong64**，各架构包内启动文件同名 `mixio`），不清楚自己机型架构可咨询主机厂家。容器只提供运行环境，不做架构转换：

| 机器架构 | 运行包来源 | 镜像 |
|---|---|---|
| x64（Intel/AMD 群晖、PC） | 官方网盘 x64 包 | 多架构 manifest 直接 `docker pull` |
| arm64（ARM 群晖等） | 官方网盘 arm64 包 | 多架构 manifest 直接 `docker pull` |
| loong64 等 | 官方网盘对应架构包 | 在本机用本仓库 Dockerfile 自行构建（`docker build -t mixly-server .`），compose 里把 `image:` 改成本地镜像名 |

容器内通过 **gcompat** 兼容层运行 glibc 二进制。若个别环境报 `Illegal instruction` 或符号缺失，把 Dockerfile 基础镜像换成 `debian:bookworm-slim` 即可（详见 README-docker.md）。

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

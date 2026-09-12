# mixly-docker

适配 [Mixly 米思齐](https://mixly.cn) 离线服务端（mixly_server）的 Docker 运行环境，面向群晖 NAS 等 amd64 设备。

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
3. 构建约 1 分钟，成功后镜像位于：

   ```
   ghcr.io/<你的GitHub用户名>/mixly-server:latest
   ```

   GHCR 登录使用 Actions 自带的 `GITHUB_TOKEN`，**无需配置任何 Secrets**。
   （可选：想同时推送到 Docker Hub，再在 Settings → Secrets and variables → Actions 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，未配置时自动跳过。）

### 4️⃣ 把 GHCR 包设为 Public（否则 NAS 拉取需要登录）

你的 GitHub 头像 → **Packages** → `mixly-server` → **Package settings** → **Change visibility** → Public。
（保持 Private 也可以，但 NAS 端需要先 `docker login ghcr.io`。）

### 5️⃣ 放置官方运行包并启动

1. 从官方百度网盘下载 `mixly_server` 压缩包（网盘地址请向 mixly.cn 官方/更新群获取）。
2. 在群晖 File Station 建目录 `/docker/mixly/mixly_server`，解压后把 **`mixio/`、`mixly/`、`mixco/` 三个文件夹**放进该目录。
   放好后应存在 `/docker/mixly/mixly_server/mixio/mixio`。
3. 下载本仓库的 [docker-compose.yml](docker-compose.yml) 放到 `/docker/mixly/`，把 `image:` 改为你自己的镜像：

   ```yaml
   image: ghcr.io/<你的GitHub用户名>/mixly-server:latest
   ```

4. Container Manager → 项目 → 新增 → 选择该 compose 文件 → 启动。

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

仅支持 `linux/amd64`（官方二进制无 arm64 版本）；ARM 架构群晖（DS223j 等）不可用。

## 兼容性说明

官方 `mixio` 是 glibc 动态链接的 x86-64 二进制（Node.js 16/pkg 打包），Alpine 上通过 **gcompat** 兼容层运行。若个别环境报 `Illegal instruction` 或符号缺失，把 Dockerfile 基础镜像换成 `debian:bookworm-slim` 即可（详见 README-docker.md）。

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

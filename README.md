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

### 6️⃣ 访问

| 入口 | 地址 | 说明 |
|---|---|---|
| MixIO / Mixly 主界面 | `https://NAS_IP:8443` | MixSuite 强制 HTTPS；自签证书提示"连接不是专用连接"时点**高级 → 继续访问** |
| 管理模式 | `https://NAS_IP:18084` | 数据管理、用户导入、在线更新 |
| MQTT | `NAS_IP:1883` | 设备接入 |
| WebSocket MQTT | `NAS_IP:8083 / 8084` | 明文 / 加密 |
| Yjs 协同 | `NAS_IP:8082 / 8086` | 明文 / 加密 |

- **HTTP(8080) 已不可用**：MixSuite 每次启动都会把 HTTP 端口固定改写为 0，只能走 HTTPS。
- 管理员默认 `admin/public`，**上线后务必在 `mixio-app/config/config.json` 中修改 `ADMIN_PASSWORD`**；离线内网可保留 `ALLOW_REGISTER`。如需外网访问，在 DSM 控制面板做端口映射或用 DSM 反向代理套 443。
- Mixly 界面内按 **CTRL+SHIFT+M** 可随时调出管理后台。

## 从 v1.x（mixly_server）迁移

1. **备份**：复制原映射目录下的 `mixio/storage` 文件夹（SQLite 数据）。
2. **换包**：下载新架构对应的 `MixSuite-linux-<架构>.zip`，解压后把内容放进映射目录（替换旧的 mixio/ mixly/ mixco/ 布局）。
3. **带数据升级**（保留用户/项目）：旧数据在 `mixio/storage`，新位置是 `mixio-app/storage`——把旧 `mixio/storage` 里的内容复制到新的 `mixio-app/storage/`，再启动。
4. **端口变化**：管理/访问入口从 `http://8080` 改为 `https://8443`（HTTP 官方已关闭）；若用了反向代理或端口映射，记得改。
5. 升级镜像本身不丢数据（数据全在映射目录里），但**升级 MixSuite 运行包前建议先停容器**。

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

（设备文件名按实际为准，`ls /dev/ttyUSB* /dev/ttyACM*` 查看；群晖 DSM 需允许 Container Manager 访问 USB。）

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

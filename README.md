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

>补充：升级到最新版（v2.0.6+）后请直接用 `latest`。若容器仍在重启，先排除这一类权限问题，再看Q11——两者的日志特征完全不同（Q8 有 `SingletonLock: Permission denied`，Q11 一片空白）。

**Q9：日志里这些报错要不要管？**

v2.0.2 起，容器正常运行时日志里只会剩下**无害噪音**，可对照下表判断：

| 日志片段 | 性质 |
|---|---|
| `dbus/bus.cc: Failed to connect to the bus` / `org.freedesktop.DBus...` | 无害。容器内无 dbus daemon，Chromium 每次启动必报几十行 |
| `XGetWindowAttributes failed for window 0` | 无害。Xvfb 虚拟显示下的窗口告警 |
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
| 容器约 120 秒后重启、退出码 0、日志无任何报错（连 `[mixio]` 都没有） | **MixIO 初始化抛错且异常被吞**，见下方 Q11 | 按Q11 逐条取证；多数情况升级到 v2.0.6 即可 |

**Q11：容器每隔约 120 秒自动重启，退出码 0，`docker logs` 完全空白**

这是 Mixly 4.0 官方包在容器里的一个已知启动链缺陷，**不是你的配置错了**，也不是 `/dev/shm` 或证书问题。根因在 `mixio-app/mixio.js`：

```
 mixio.js:929    if (!fs.existsSync(storage)) { ...建库、写 filter.json... }
 mixio.js:6626   filterPath = <storage>/reserve/filter.json
 mixio.js:6756   JSON.parse(fs.readFileSync(filterPath))     ← 无 try/catch
 mixio.js:7683   daemon_start().then(() => startOnce())     ← 无 .catch
 nw-boot.html    探测 8443，120 次 × 500ms 失败后放弃 → 退出码 0
```

官方**只在 `storage` 目录不存在时**才创建 `filter.json`；而容器为了 `chown`/`chmod` 会预先建好 `storage`，官方因此认为「已初始化」而跳过创建 → 6756 行读 `filter.json` 得到 `ENOENT` 并抛错 → 由于 `.then()` 没有 `.catch()`，异常被彻底吞掉：不打印、不退出、8443 永不监听 → 启动器探测约 120 秒后放弃、退出码 0 → 重启策略再拉起。

**v2.0.6 起镜像已自动预置 `storage/reserve/filter.json`，多数情况下升级镜像即可正常启动：**

```bash
# 1) 换成新镜像
docker rm -f <容器名>
docker run -d --name <容器名> --restart unless-stopped --shm-size=1g \
  -p 8443:8443 -p 18084:18084 -p 1883:1883 -p 8083:8083 -p 8084:8084 -p 8082:8082 -p 8086:8086 \
  -v /你的路径/mixly_server:/opt/mixly_server \
  ghcr.io/realkiro/mixly-server:latest

# 2) 确认这行出现（说明预置成功）
docker logs <容器名> 2>&1 | grep 已预置
```

如果升级后仍反复重启，说明是另一类问题，请按下面顺序取证并把结果反馈给官方：

```bash
# A) mixio.js 顶层加载失败时，nw-main.js 会把完整堆栈写到这个文件
#    （最常见的具体原因：NW.js 内置 Node 版本不支持 node:sqlite）
docker exec <容器名> sh -c 'cat /opt/mixly_server/mixio-app/runtime/nw-main-error.log'

# B) 关键数据文件是否齐备（filter.json 必须存在且是合法 JSON）
docker exec <容器名> sh -c 'ls -la /opt/mixly_server/mixio-app/storage /opt/mixly_server/mixio-app/storage/reserve'

# C) 端口到底有没有起来
docker exec <容器名> sh -c 'netstat -lntp | grep -E "8443|18084"'
```

v2.0.6 起入口脚本会自动完成以下动作，不必再手工取证：

- 预置 `storage/reserve/filter.json`（缺失或非法时自动修正为 `{}`）
- 主动捕获并打印 `runtime/nw-main-error.log` 的完整内容（NW.js 不会把它写进 `docker logs`）
- 退出码 0 时明确指出「这是就绪探测超时，不是正常退出」并打印取证命令
- 就绪检查期间输出 `storage` 目录实况

## 致谢与声明

- [Mixly 米思齐](https://mixly.cn) 及其服务端 [mixly2/mixio](https://gitee.com/mixly2/mixio) —— 本仓库仅提供运行环境适配，Mixly 软件版权归原团队所有，请从官方渠道获取运行包并遵守其使用条款。

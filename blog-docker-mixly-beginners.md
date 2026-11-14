# 零基础也能搞定：用 Docker 把 Mixly 4.0 部署到 NAS 或家用电脑

> Mixly 4 的 **MixSuite 本身就是服务端**：不管装在 Windows 还是用 Docker 跑，学生端都是浏览器打开 `https://IP:8443`。这篇教程不改造软件，只把这台服务端用 Docker 变成**资源开销更低、无人值守、可搬迁、跨硬件**的常驻服务。
>
> 全程**不用学 Linux、不用自己编译镜像**：Windows 上装个 Docker Desktop 就行，容器里的 Linux 环境由镜像自带；在 GitHub 上点个 Star、Fork 一下，构建交给 Actions 自动完成，连这一步都不想做也可以直接用现成镜像。

---

## 先说清楚：Mixly 4 本来就是「服务端 + 浏览器」

[Mixly（米思齐）](https://mixly.cn) 是中小学创客课、信息技术课常用的图形化编程工具。**从 4.0 起，官方只有一个发行版：MixSuite**（内置 MixIO）。它不再是"每台学生机装一个的单机软件"，而是一个 NW.js 应用形态的**服务端**：

- 在某一台机器上运行 MixSuite，它就在 8443 端口提供 HTTPS 服务（官方强制 HTTPS、自带自签证书）；
- 同一网络里的电脑、平板用浏览器打开 `https://这台机器的IP:8443` 就能进 Mixly 编辑器；
- 账号、项目、上传文件、MQTT 设备数据都保存在这台机器上。

**这一点跟操作系统无关。** 在 Windows 上安装启动官方 MixSuite、在 Linux / 信创电脑上跑官方包、或用本文的 Docker 镜像跑起来，学生端打开的是**同一个页面、同一套功能**。所以本文不是"把单机软件改造成网络版"，而是**把同一个服务端，换成一种更省心的运行方式**。

那 Docker 做了什么？MixSuite 是个 NW.js（Chromium）桌面应用，需要一整套图形库和一个显示服务才能启动：在 Windows 上由桌面会话承载，在容器里则由镜像自带的 Xvfb 虚拟显示 + 前台进程 + 重启策略承载。于是同一个程序，从"要有人登录桌面双击打开、窗口不能关"变成"开机自启、崩了自动拉起、不占桌面的后台服务"。

```
官方 Linux 运行包 ─┐
                  ├─→ ./mixly_server 映射目录 ─→ 容器 ─→ 浏览器 https://IP:8443
运行环境镜像 ─────┘              ↑
                          数据写回这里，删容器不丢
```

### 两个必须先知道的前提（不知道一定会卡住）

1. **镜像里没有 Mixly 本体，而且容器里要放的是 Linux 版。** 出于版权和体积考虑，镜像只装了"运行环境"（Debian + 图形依赖 + Xvfb，约 300MB）。你要从官方渠道下载 **Linux 版** `MixSuite-linux-<架构>.zip`（x64 / arm64 / loong64，最新版已内置 `mixio-app` / `mixly` / `mixco` / `mixmo`），把内容放进映射目录；只有 `mixai` 需要另外下载解压放进同一层 —— **不是你在 Windows 上装的那个安装包**，两者不能混用。
2. **运行环境镜像不用自己编译。** 给项目点个 **Star**、**Fork** 到自己账号下，GitHub Actions 会帮你把 amd64 / arm64 / loong64 三种架构一次构建好、推到你自己的账号里，全程在网页上点几下，不用装 git、不用装编译环境、不用敲构建命令。如果连这也不想弄，**也可以直接用维护者已经构建好的公开镜像**，配置文件一行都不用改。

一句话记住：**运行环境用 Fork 自动构建（或直接拿现成的），官方 Linux 运行包自己下，数据放自己硬盘**，三者拼起来就是完整服务。

---

## 我一直在 Windows 上跑 MixSuite，凭什么还要 Docker？

先说结论：**两边的学生端完全一样** —— 都是浏览器打开 `https://IP:8443`，MixIO 账号、项目共享、协同编辑、MQTT 设备接入一个不少，因为跑的是同一个官方运行包。差别只发生在**当服务器的那台机器**上。

米思齐的用户大多是信息技术老师，熟悉 Windows、不熟悉 Linux 和 Docker，这个顾虑很正常。但这里 Docker 不是让你改用 Linux：

> **在 Windows 上它就是一个普通安装程序（Docker Desktop）**，装完跟微信、QQ 一样在任务栏有个图标。真正跑 MixSuite 的那套 Linux 环境被关在「容器」里，是项目镜像自带的——你不用装、不用配、也看不见它。你的 Windows 桌面、驱动、Office、机房还原卡和其它教学软件，一个字节都不会被改动。

### 最实在的差别：CPU、内存和电费

先把话说准：**Docker 不是虚拟机，容器本身几乎不额外吃 CPU 和内存** —— MixSuite 内嵌的是完整 Chromium，这部分开销在 Windows 里和容器里基本一样。真正省下来的是**宿主系统那一层**：

- **省掉整个 Windows 桌面**：图形会话、资源管理器、显卡驱动、杀毒、系统更新和各种常驻托盘程序，空闲时就要占掉相当一部分内存与 CPU；Linux / NAS 上没有这些，容器用镜像自带的 Xvfb 虚拟显示（一块 1280×800 的虚拟屏幕）顶替桌面，非常轻。
- **整机门槛低**：本方案给容器留 1.5GB 以上内存、共享内存 1GB 就够了，一台 2GB 内存的旧小主机或 ARM 群晖就能带得动；同样的服务放在 Windows 上，光桌面本身就已经吃掉大半预算。
- **长期开机更划算**：NAS / 小主机本来就是为 7×24 低功耗运行设计的，功耗和噪音通常只有台式机的零头；配上 `restart: unless-stopped` 开机自启、崩溃自动拉起，也不会被 Windows 更新后的自动重启、休眠或注销登录打断服务。

所以如果那台 Windows 平时还要给人用，或者你想把一台闲置旧设备 / NAS 利用起来，Linux + Docker 在资源上明显更划算。

> 但别指望容器能把 Chromium 的内存变没：机器只有 1GB 内存时，两种跑法都吃力，该加内存还是得加。

### 差别只在这台服务器机器上

| | Windows 上直接跑官方 MixSuite | 用 Docker 跑同一个 MixSuite |
|---|---|---|
| 学生端 / 功能 | 浏览器访问 `https://IP:8443`，功能齐全 | **完全一样**（同一个官方运行包） |
| 启动方式 | 要有人登录 Windows 桌面、双击启动，窗口不能关；没配开机自启时，重启后服务不会自己回来 | 容器后台运行，`restart: unless-stopped`，开机自启、崩溃自动拉起，全程无人值守 |
| 桌面占用 | 占着一台 Windows 的桌面会话，注销登录或关掉窗口服务就断 | 不依赖图形桌面（容器内 Xvfb 虚拟显示），可以跑在没有显示器的 NAS、小主机上 |
| 资源开销 | Windows 桌面、杀毒、更新等常驻进程和图形会话都要吃 CPU / 内存 | 无宿主桌面层，Xvfb 虚拟显示很轻；2GB 内存的 NAS / 小主机即可，长期开机功耗低 |
| 能跑在哪 | Windows（官方另有 Linux 包） | Windows / Linux / 群晖 NAS / ARM / 龙芯，一套多架构镜像按设备自动选 |
| 环境依赖 | 跟这台 Windows 的系统状态绑定，换机要重配一遍 | 依赖全在镜像里，宿主机只要装 Docker；不写注册表、不改系统环境 |
| 升级 | 在这台机器上手动下载新版、覆盖程序，还要小心别覆盖数据 | 运行环境 `docker compose pull` 一条命令；官方包升级只换程序文件，数据留在映射目录 |
| 备份 / 迁移 | 自己找 MixSuite 的数据目录、手工复制，换机还要重配环境 | 数据全在 `mixly_server/` 一个文件夹，复制到另一台机器就能原样启动 |
| 搞砸了 | 可能要卸载重装、清理环境 | `docker compose down` 删容器重建，Windows 不受影响 |

一句话：**Docker 换来的不是新功能，而是「更低的资源开销 + 无人值守 + 跨硬件 + 一个文件夹就能搬走」。**

### 最让人犹豫的四件事

- **「既然浏览器访问一样，Docker 岂不是多此一举？」** → 如果你已经有一台 7×24 常开、有人维护、也不在意电费和内存占用的 Windows 机器，直接用官方版确实就够了。想省下桌面那部分资源、放到低功耗 NAS / ARM 小主机、让服务开机自启，或者以后换机器不想重配环境，Docker 才显出价值。
- **「我不懂 Linux」** → 不用懂。你全程只跟两样东西打交道：一个放运行包的**文件夹**，和一个浏览器里的**网址**。容器里的 Linux 是镜像作者配好的，跟你的 Windows 互不干扰。
- **「要敲很多命令吧」** → 真正必须敲的只有第 5 步那条 `docker compose up -d`，复制粘贴即可；`docker ps`、`docker logs` 都是出问题时才用的查看命令。用群晖 NAS 更是全程点鼠标（Container Manager → 项目 → 新增），一行命令都不用。
- **「别把我电脑搞乱了」** → Docker 不会往系统目录、注册表里塞依赖。不想用了执行 `docker compose down`、删掉那个文件夹，就恢复原样，可以理解成一个带后台服务的「绿色软件」。

### 零成本试一下，再决定

不想一上来就动 NAS？可以先在自己的 Windows 电脑上试：装好 Docker Desktop（第 2 步），镜像选「直接用现成镜像」（第 3 步），十几分钟就能在 `https://localhost:8443` 看到和官方版一模一样的界面。不满意就停掉容器、删掉文件夹，电脑上不留痕迹。跑通了再搬到常开的 NAS 或旧电脑上，把 `mixly_server/` 和 compose 文件原样复制过去即可，数据不会丢。

> ⚠️ 如果这台 Windows 上**已经在跑官方 MixSuite**，8443 端口会被占用：先停掉它再试，或把 compose 里的 `8443:8443` 改成 `18443:8443`，然后访问 `https://localhost:18443`。两者不要同时抢同一个端口。

### 也诚实地说：什么情况下别折腾

- 已有一台 7×24 常开、有人维护的 Windows 电脑，只在自己班上用，也不在意它一直占着桌面和内存 → 官方 Windows 版直接跑就够了，没必要上 Docker。
- 课堂主力是给开发板烧录 → 容器里要额外透传 USB 串口，Windows 上的 Docker Desktop（WSL2）还多一层 USB 透传配置，纯烧录场景不如官方 Windows 版直接。
- 不想在服务器上装任何新软件，也没有 NAS 或多台设备的需求 → 保持现状即可，Docker 的收益主要在运维侧。

---

## 第 0 步：四个词，看懂后面所有操作

完全没接触过 Docker 也没关系，先认这四个词就够了：

| 词 | 大白话 | 本文里对应 |
|---|---|---|
| 镜像 image | 装好环境的"软件安装包"，只读 | `${MIXLY_IMAGE:-ghcr.io/realkiro/mixly-server:latest}` |
| 容器 container | 安装包跑起来之后的那个"程序" | 名字叫 `mixly-server` |
| 映射 / 卷 volumes | 容器和主机共用的文件夹，程序和数据都放这儿 | `./mixly_server` |
| 端口 ports | 服务的门牌号，写法是 `主机端口:容器端口` | `8443:8443` |

**最重要的一条**：容器可以随便删了重建，映射目录里的东西才是你的。备份也只需要备份那一个文件夹。

---

## 第 1 步：准备清单

| 需要什么 | 说明 |
|---|---|
| 一台常开的设备 | Windows / macOS 电脑、Linux 小主机、群晖等 NAS 都行；长期开机推荐低功耗 NAS 或旧小主机 |
| 内存 ≥ 2GB 可用 | 容器建议留 1.5GB 以上，共享内存 1GB；这是**整机**门槛，无桌面的 Linux / NAS 比带桌面的 Windows 更容易达标 |
| 磁盘 ≥ 3GB | 镜像约 300MB，官方运行包解压后较大 |
| Docker | 第 2 节装 |
| 官方 **Linux 版**运行包 | `MixSuite-linux-<架构>.zip`（已内置 mixio / mixly / mixco / mixmo）+ 可选单独下载的 `mixai` 包，从 [mixly.cn](https://mixly.cn) 官网 / 官方网盘获取，**不是 Windows 安装包** |
| GitHub 账号 | Star + Fork 用；如果直接用现成镜像，这个也可以不要 |
| 机器的固定 IP | 在路由器里给这台设备做 DHCP 保留，否则重启后地址变了，收藏的网址就失效了 |

> 不需要的东西：不用装 git、不用下载源码到本地、不用装编译工具、不用自己 `docker build`。镜像由 GitHub 的机器帮你造。

### 搞清楚自己机器的架构（很重要）

容器里是 Linux 环境，所以要按机器架构下载对应的 **Linux 版**运行包 —— 跟你在 Windows 上装的 MixSuite 不是同一个包，不能混用。下错了容器会明确报错、起不来。先查一下：

```bash
uname -m          # Linux / macOS / 群晖 SSH 里执行
```

Windows 用 PowerShell 执行 `echo $env:PROCESSOR_ARCHITECTURE`。对照表：

| 命令输出 / 机型 | 该下载哪个包 |
|---|---|
| `x86_64` / `AMD64` / Intel、AMD 的 PC 和大部分群晖 | `MixSuite-linux-x64.zip` |
| `aarch64` / `arm64` / ARM 群晖、树莓派、ARM 信创电脑 | `MixSuite-linux-arm64.zip` |
| `loongarch64` / 龙芯 | `MixSuite-linux-loong64.zip` |

实在拿不准，直接问设备厂商客服"这台机器是 x64 还是 arm64"。

> 好消息：**镜像不用挑架构**。Actions 构建出来的是三架构合一的多架构镜像，Docker 会按你的设备自动选对应版本；你只要保证**官方运行包**下对架构就行。

---

## 第 2 步：装 Docker

**Windows / macOS**：去 Docker 官网下载 **Docker Desktop**，一路下一步安装。Windows 会要求开启 WSL2 或 Hyper-V，按提示重启即可。启动后任务栏出现小鲸鱼图标、状态不报错，就算好了。

**Linux（Ubuntu / Debian 等）**：按 Docker 官方文档安装 `docker-ce` 和 `docker-compose-plugin`，或者用官方的一键脚本。装完把自己加进 docker 组，避免每条命令都要 `sudo`。

**群晖 DSM 7.x**：套件中心搜索 **Container Manager**（旧版叫 Docker）安装，全程图形界面，不用敲命令。

装完验证一下（群晖可以跳过，直接进图形界面）：

```bash
docker --version
docker compose version
```

> 注意是 `docker compose`（中间空格），不是老教程里的 `docker-compose`（中间横线）。两条都能打印出版本号就 OK。

---

## 第 3 步：Star + Fork，让 GitHub Actions 自动帮你造镜像

这是本文唯一需要"折腾"的一步，但全程在浏览器里点，不用碰命令行。

1. 打开 [RealKiro/mixly-docker](https://github.com/RealKiro/mixly-docker)，点右上角 **Star**，再点 **Fork** → **Create fork**，把仓库复制到自己账号下。
2. 进入**你 Fork 的仓库**（注意地址里是你自己的用户名）→ **Actions** 标签 → 按提示点 **I understand my workflows, go ahead and enable them**。
   > GitHub 出于安全考虑，Fork 来的仓库默认不会自动运行工作流，所以这里需要手动启用一次，属于平台规则，不是配置错了。
3. 左侧工作流列表选 **docker-ci** → 点 **Run workflow** → 再点一次绿色按钮确认。
4. 剩下的就是**全自动**了：Actions 会先跑冒烟测试，再构建 amd64 / arm64 / loong64 三个架构，最后合并成一个多架构镜像推到你账号下。等几分钟（含 ARM/龙芯的模拟构建，会慢一点），状态变绿即成功。产出：

   ```
   ghcr.io/<你的GitHub用户名>/mixly-server:latest
   ```

5. 点右上角头像 → **Packages** → `mixly-server` → **Package settings** → **Change visibility** → 改成 **Public**。
   > 保持 Private 也行，但 NAS 端要先执行 `docker login ghcr.io`（密码用有 `read:packages` 权限的 Personal Access Token）。改成 Public 最省事。
6. 构建完成后打开这次运行的 **Job Summary**，里面直接写好了你的镜像地址和该填的 `MIXLY_IMAGE`。照抄到 `.env` 里即可（第 5 步讲），**不用去改 compose 文件**。
7. 想确认镜像真的能拉，可在电脑或 NAS 上执行 `docker pull ghcr.io/<你的用户名>/mixly-server:latest`，能拉下来就说明这一步完成了。

> 几个小提示：GitHub 用户名在镜像地址里**必须全小写**；整个流程用 Actions 自带的 `GITHUB_TOKEN`，**不需要配置任何 Secrets**；以后仓库有更新，同步你的 Fork 后再点一次 **Run workflow**（或推一个 `v*` 标签）就会自动重新构建。CI 用 `github.repository_owner` 生成镜像名，所以 **Fork 之后镜像自动落在你自己的账号下**，不会推到原作者那里。

### 懒人方案：直接用维护者已经构建好的镜像

如果不想 Fork、不想等构建，可以**直接跳过这一步，第 5 步也什么都不用配置**：

```
ghcr.io/realkiro/mixly-server:latest
```

这是维护者通过同一条 Actions 流水线构建好的公开镜像，同样是 amd64 / arm64 / loong64 三架构，`docker pull` 无需登录。compose 里写的是 `${MIXLY_IMAGE:-ghcr.io/realkiro/mixly-server:latest}`——**不设置变量时默认就是它**，下载下来直接用即可。

| | Fork 后用 Actions 自建 | 直接用现成镜像 |
|---|---|---|
| 操作 | 点 Star、Fork、启用 Actions、Run workflow，再在 `.env` 写一行 | 什么都不用做 |
| 镜像归属 | 你自己账号下，版本可控、随时可重建 | 维护者账号下 |
| 更新 | 自己重跑一次 Actions 就是最新 | 等维护者发布新版本 |
| 适合 | 长期用、要多台设备部署、想自己掌握版本 | 先跑通看看、临时用、纯新手试水 |

两条路得到的运行环境是一样的，后面所有步骤完全相同。**建议先拿现成镜像跑通，觉得好用了再 Fork 一份自己掌控版本**——切换时只需在 `.env` 写一行 `MIXLY_IMAGE=...`，compose 文件和数据都不用动。

---

## 第 4 步：放官方运行包（最容易翻车的一步）

先建一个总目录。下面用群晖的 `/docker/mixly/` 举例，Windows 可以换成 `D:\mixly\`，道理完全一样：

```
/docker/mixly/
├── docker-compose.yml          ← 第 5 步的配置文件放这一层
├── .env                        ← 可选：只有用自己 Fork 构建的镜像才需要（复制 .env.example）
└── mixly_server/               ← 官方包解压后，内容全放这一层
    ├── MixlyServer             ← 启动器
    ├── MixlyServer.desktop
    ├── firstrun.sh
    ├── .host/                  ← NW.js 运行时（nw 在这里）
    ├── mixio-app/              ← MixIO 服务端（storage / config / logs 都在这里）
    ├── mixly/                  ← Mixly 图文编程（最新版包内置）
    ├── mixco/                  ← MixCO 自学课程（最新版包内置）
    ├── mixmo/                  ← MixMO 手机 App 设计（最新版包内置）
    ├── mixai/                  ← MixAI：需单独下载解压放入
    └── user-data/              ← 首次运行后自动生成
```

**最新版 MixSuite 已经把大部分组件打在一个包里了**：按机器架构下载 Linux 版 `MixSuite-linux-<架构>.zip`（x64 / arm64 / loong64，不是 Windows 安装包），解压后里面就有 `mixio-app`（MixIO 服务端）、`mixly`、`mixco`、`mixmo` 这几个并列目录，以及 `MixlyServer`、`.host/` 等。**把解压出来的全部内容**放进 `/docker/mixly/mixly_server/` 即可。

**只有 `mixai` 要另外下载**：MixAI 交互体验包不在 MixSuite 里，单独下载后解压，把内容放进**同一层**，与 `mixio-app/` **并列**（即 `/docker/mixly/mixly_server/mixai/`）。不装它不影响其他功能，只是 `/mixai` 打不开。

> 如果手上是旧版或分包发行的包，解压后缺哪个组件就单独补哪个，层级同样是并列 —— 以实际解压出来的内容为准。

放完核对这几项是否都在**同一层**：

- [ ] `mixly_server/MixlyServer`、`.host/nw`、`mixio-app/mixio.js` 存在
- [ ] `mixly_server/mixly/`、`mixco/`、`mixmo/` 在同一层（最新版包自带）
- [ ] 需要 MixAI 时，`mixly_server/mixai/` 也在同一层

### ⚠️ 最常见的错误：多套了一层文件夹

```
❌ /docker/mixly/mixly_server/mixly_server/MixlyServer      主体包套了一层
❌ /docker/mixly/mixly_server/mixai/mixai/                  MixAI 包整个拖进去了
✅ /docker/mixly/mixly_server/MixlyServer
✅ /docker/mixly/mixly_server/mixai/                        与 mixio-app 并列
```

解压软件经常会自作主张新建一个同名文件夹，请进入文件夹里**选中全部内容**再复制过去，而不是把文件夹整个拖进去。主体包多套一层时入口脚本有自动兼容（会打 WARN 并自动进子目录），但**单独放的 mixai 放错层级不会兼容**，结果就是 `/mixai` 打不开。

架构下错了也不用猜：容器启动时会读取 `.host/nw` 校验架构，日志直接告诉你该下哪个架构的包。

---

## 第 5 步：写好配置文件，一键启动

下载仓库里的 [`docker-compose.yml`](https://github.com/RealKiro/mixly-docker/blob/main/docker-compose.yml)，放到 `/docker/mixly/`（也就是 `mixly_server/` 的**上一级**）。

compose 里的 `image:` 是这样写的：

```yaml
    image: ${MIXLY_IMAGE:-ghcr.io/realkiro/mixly-server:latest}
```

「`:-` 后面」就是默认值：不设置任何东西，用的就是维护者构建的公开镜像，免登录直接拉。所以这里分两种情况：

**直接用现成镜像** → 什么都不用动，直接看下面的「启动」。

**用自己 Fork 构建的镜像** → 不用改 compose 文件，任选一种方式告诉它用哪个镜像：

- 推荐：把仓库里的 `.env.example` 复制成 `.env`（和 compose **同一目录**），填一行，地址照抄 Actions 的 Job Summary：

  ```ini
  MIXLY_IMAGE=ghcr.io/你的用户名/mixly-server:latest
  ```

- 或者启动时临时指定：`MIXLY_IMAGE=ghcr.io/你的用户名/mixly-server:latest docker compose up -d`
- 群晖 Container Manager 若不读 `.env`，就在项目的「环境变量」里加 `MIXLY_IMAGE`；也可以直接把 compose 里的默认值换成自己的地址。

想确认当前到底用的哪个镜像，执行 `docker compose config --images` 看输出即可。

其余内容保持原样。特别提醒两行别删：

- `shm_size: '1gb'`：MixSuite 内嵌的是完整 Chromium，Docker 默认的 64MB 共享内存不够，会导致渲染进程悄悄退出、容器隔一两分钟自己重启，而日志里看不出原因。
- `./mixly_server:/opt/mixly_server`：这个 `./` 是**相对于 compose 文件所在目录**的，所以两者必须是上面那个上下层关系。

启动：

```bash
cd /docker/mixly
docker compose up -d
```

第一次会从网上拉取镜像，等它下载完再启动，属于正常现象。

**群晖图形界面**：Container Manager → **项目** → **新增** → 选择 `/docker/mixly/` 这个目录（不同 DSM 版本按钮叫"使用现有 docker-compose.yml"或"导入"）→ 一路下一步 → 启动。也可以 SSH 登录 NAS 后执行上面同样的命令。

启动后看状态，第一次请耐心等 1~3 分钟：

```bash
docker ps                        # STATUS 列显示 healthy，才是真的能用了
docker logs -f mixly-server      # 看启动过程，Ctrl+C 退出（不会停容器）
```

`running` 不代表服务已就绪——`healthy` 才代表 8443 端口真的有 MixIO 在应答。首次启动要初始化数据库、尝试拉取证书（离线环境会等 10~30 秒超时），慢一点是正常的。

---

## 第 6 步：打开浏览器

在**同一局域网**的另一台设备上打开：

```
https://<那台机器的IP>:8443
```

例如 `https://192.168.1.50:8443`。

这正是 Windows 上直接跑官方 MixSuite 时的访问方式 —— 学生端看到的界面和功能没有任何区别，换 Docker 只是换了服务器的运行方式。

浏览器会提示"连接不是专用连接 / 您的连接不是私密连接"——**这是正常的**，因为官方运行包用的是自签证书。点 **高级 → 继续访问**（Chrome 若没出现"高级"，在页面空白处键入 `thisisunsafe` 也可放行），就能看到 MixIO 首页，从首页进 Mixly 编辑器。

| 入口 | 地址 | 用途 |
|---|---|---|
| 主界面 | `https://IP:8443` | Mixly 编辑器、课程、首页各产品入口 |
| 管理模式 | `https://IP:18084` | 数据管理、用户导入、在线更新 |
| 管理后台快捷键 | 编辑器内 `CTRL + SHIFT + M` | 随时调出后台 |
| MixMO 手机 App 设计 | `https://IP:8443/mixmo` | 需 `mixmo/` 与 `mixio-app/` 并列（最新版包内置） |
| MQTT / 协同 | `1883`、`8083`、`8084`、`8082`、`8086` | 设备接入、协同编辑，一般不用手动访问 |

默认管理员账号 `admin` / 密码 `public`。

> **为什么 `http://IP:8080` 打不开？** 不是你配错了。MixSuite 每次启动都会强制把 HTTP 端口置 0，只提供 HTTPS，这是官方 4.0 起的设计。

---

## 第 7 步：立刻改密码（别拖到"以后再说"）

默认密码是公开的，只要有人知道这个地址就能进后台改配置、清数据。花两分钟做三件事：

**1. 改管理员密码（推荐用面板）**

进入管理后台 → **基础管理** → 找到配置表里的 `ADMIN_PASSWORD` 一行改掉 → 点 **保存设置并重新启动**。几秒后生效，容器不用重启。

也可以在服务器上直接改文件，但**必须先停容器**：

```bash
docker stop mixly-server
# 编辑 <映射目录>/mixio-app/config/config.json 里的 ADMIN_PASSWORD
docker start mixly-server
```

> 进程只在启动时读一次配置；如果没停容器就改文件，之后又在面板点"保存设置并重新启动"，内存里的旧值会把你的修改覆盖回去。另外这个密码在 `config.json` 里是**明文**（官方实现），别把映射目录共享出去，备份和截图记得脱敏。

**2. 关掉随意注册**：只给内部账号用时，在面板配置里把 `ALLOW_REGISTER` 设为 `false`。

**3. 不要把这些端口直接映射到公网**：尤其 `18084`（管理端）和 `1883` / `8083` / `8084`（MQTT 侧内置通用账号）。真要外网访问，请走反向代理 / 隧道，并给 `/admin` 再加一层访问验证，具体做法见文末"选读"。

---

## 第 8 步：日常操作速查

| 想做什么 | 命令（在 compose 文件所在目录执行） |
|---|---|
| 启动 / 停止 | `docker compose up -d` / `docker compose stop` |
| 重启 | `docker compose restart mixly` |
| 看日志 | `docker logs -f mixly-server` |
| 看状态 | `docker ps` |
| 更新镜像 | `docker compose pull && docker compose up -d` |
| 彻底重建容器 | `docker rm -f mixly-server` 后再 `docker compose up -d` |

**数据在哪里**：全在 `mixly_server/mixio-app/` 下的 `storage/`（SQLite 用户与项目）、`config/`（配置 + 证书）、`logs/`，以及 `user-data/`。备份整个 `mixly_server/` 就等于备份了全部；升级镜像、重建容器都不会动这些数据。

**升级 Mixly 官方运行包（不需要备份）**

这里有个好消息：**运行文件是通过路径映射进容器的，升级不需要备份**。官方程序和你所有的数据都在宿主机的 `mixly_server/` 里，容器只是读取它；停容器、换包、重建容器都不会动这些数据（就是第 0 步说的「映射目录里的东西才是你的」）。所谓「升级会丢数据」，只发生在一种情况：把新解压的整包连数据目录一起覆盖过去。

所以升级只要三步 —— 停容器、只替换程序文件、再启动：

```bash
docker compose down                                  # 1. 停容器，数据留在宿主机

# 2. 解压新版主体包，只同步程序文件，跳过数据目录
unzip -o ~/Downloads/MixSuite-linux-x64.zip -d /tmp/mixnew
SUITE_SRC=/tmp/mixnew/mixly_server       # 按你解压出来的实际文件夹名改（也可能叫 MixSuite-linux-x64）
rsync -a \
  --exclude='mixio-app/storage/' --exclude='mixio-app/config/' \
  --exclude='mixio-app/logs/'   --exclude='mixio-app/runtime/' \
  --exclude='user-data/' \
  "$SUITE_SRC/"  mixly_server/

docker compose up -d                                 # 3. 按原方式启动
```

要保留的是 `mixio-app/` 下的 `storage/`（SQLite 用户与项目）、`config/`（配置 + 证书）、`logs/`、`runtime/`，以及根目录的 `user-data/`；其余程序文件（启动器、`.host/`、`mixio-app/mixio.js`、`ejs/`、`js/`，以及并列的 `mixly/`、`mixco/`、`mixai/`、`mixmo/` 等组件目录）都可以放心覆盖。**单独放的 `mixai` 出了新版，同样解压覆盖到并列目录即可，不涉及数据。** Windows 用户用解压软件解到临时目录后，在文件管理器里跳过这几个数据目录复制即可（也可用 WSL 里的 rsync）。启动时入口脚本会自动给新版 `mixio.js`、`ejs/`、`js/` 重打补丁，不用手动处理。

⚠️ 只有用 `cp -a /tmp/mixnew/.../. mixly_server/` **整包覆盖**才危险：新版包里同样带着空的 `storage/`、`config/` 目录，会把现有数据冲掉，那种做法才需要先备份。**把程序和数据分开替换，就不必备份**；如果你把官方运行包单独放一个目录、数据目录另做映射，升级时整个程序目录直接换新，数据更是完全不用碰。

> 定期把 `mixly_server/` 冷备份一份仍是好习惯，但那是为了防硬盘故障，不是为了升级。

**Actions 重新构建完，服务器上的版本却没变？** 本地已有同名 `latest` 时，`docker compose up` 不会主动去拉新镜像，必须显式执行一次 `docker compose pull && docker compose up -d`。从现成镜像切换到自己 Fork 的镜像同理：写好 `.env` 里的 `MIXLY_IMAGE` 后执行这两条命令即可，数据不受影响。

---

## 第 9 步：出问题照着这张表查

| 现象 | 原因 / 怎么办 |
|---|---|
| 容器一启动就退出，日志写"未检测到 Mixly 官方运行包" | 第 4 步路径放错了，主体包多套了一层文件夹。放**文件夹里面的内容** |
| `/mixai` 打不开（404） | MixAI 不在 MixSuite 包内，需单独下载解压，且要与 `mixio-app/` **并列**；别多套一层变成 `mixai/mixai/`（见第 4 步） |
| 日志提示"运行包与机器架构不匹配" | 下错架构的 zip，日志里会直接写该下载哪个，换包即可；也可能是误放了 Windows 版安装包，容器只认 Linux 版 |
| `docker compose up` 提示拉取镜像失败 / `denied` | Fork 构建出的 Package 还是 Private：到 Packages → Package settings 改成 Public，或在 NAS 上先 `docker login ghcr.io`（密码用有 `read:packages` 权限的 Token） |
| Actions 页面一片空白 / 找不到 Run workflow | Fork 仓库的 Actions 默认未启用，回到第 3 步第 2 点，先点"启用 workflows" |
| 容器每隔一两分钟自己重启，日志看不出原因 | `shm_size: '1gb'` 被删了，或机器内存不足（留 1.5GB 以上）。用 `docker run` 时等价参数是 `--shm-size=1g` |
| 状态 running 但网页打不开 | 先看 `docker ps` 的 healthy；首次启动等 1~3 分钟；再看 `docker logs -f mixly-server`。离线环境拉官方证书会卡 10~30 秒，属正常 |
| 浏览器提示"不安全" | 自签证书，点高级 → 继续访问 |
| 日志里一堆 `Failed to connect to the bus`、`dbus`、`crashpad` 报错 | 无害噪音，容器里没有桌面总线。**以浏览器能否打开为准，不要以日志是否干净为准** |
| `.env` 里写了自己的镜像，容器却还在用默认镜像 | `.env` 必须和 `docker-compose.yml` **同目录**、文件名就是 `.env`；改完要 `docker compose up -d` 重建容器（`restart` 不会重新解析）。用 `docker compose config --images` 看实际生效的镜像 |
| 群晖导入 compose 后启动失败 | 检查 `./mixly_server` 是否真的在 compose 文件同级的下一层，以及共享文件夹权限；用自建镜像时确认 Container Manager 读到了 `MIXLY_IMAGE` |
| 烧录时找不到串口 | 见下面"选读"，`devices` 段要按需开启 |

排查万能三连：`docker ps` 看 healthy → `docker logs -f mixly-server` 看报错 → 确认 `https://IP:8443` 而不是 http。

---

## 选读：给开发板烧录、以及外网访问

**串口 / USB 烧录**：Mixly 要通过串口给开发板下载程序。在 `docker-compose.yml` 里取消注释这几行：

```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
    group_add:
      - dialout
```

⚠️ 这是**按需开启**而不是必填：宿主机上必须真的存在这个设备节点，否则 Docker 会直接拒绝启动并报 `no such file or directory`。没插开发板就保持注释。插了还报错，先 `ls /dev/ttyUSB* /dev/ttyACM*` 查真实名字（有些芯片是 `ttyACM0`）；群晖 DSM 还要在 Container Manager 设置里允许容器访问 USB。

**公网访问 / 域名 /admin**：本项目支持用 `MIXIO_ADMIN_BASE=/admin` 把管理后台挂到 `https://域名/admin`，配套需要反向代理或 Cloudflare Tunnel。这一步涉及证书、路径规则和安全策略，属于进阶内容，建议先按本文在内网跑通，再照仓库 [README.md](https://github.com/RealKiro/mixly-docker#管理后台走-admin) 的"管理后台走 /admin"和"安全加固"两节配置。

---

## 收尾：一张清单核对

- [ ] Docker 装好，`docker compose version` 能打印版本
- [ ] 已 Star + Fork，`docker-ci` 跑绿并拿到自己的镜像地址（或决定直接用现成镜像）
- [ ] 官方 MixSuite 运行包**内容**（不是外层文件夹）放进 `mixly_server/`
- [ ] `docker-compose.yml` 放在它的上一级；用现成镜像什么都不用动，自建镜像则在同目录 `.env` 写好 `MIXLY_IMAGE`
- [ ] `docker compose up -d` 后 `docker ps` 显示 **healthy**
- [ ] `https://IP:8443` 能打开（证书提示点继续）
- [ ] **管理员密码已改**，`ALLOW_REGISTER` 按需要关闭
- [ ] 知道数据都在 `mixly_server/` 里，备份只需备份这一个文件夹

---

## 声明

本文使用的是开源项目 [RealKiro/mixly-docker](https://github.com/RealKiro/mixly-docker)，它只提供**运行环境适配**，不包含 Mixly 程序本体；运行环境镜像由项目维护者或你自己的 Fork 通过 GitHub Actions 构建。Mixly / MixSuite 软件版权归 [Mixly 米思齐](https://mixly.cn) 及其团队所有，请从官方渠道获取运行包并遵守其使用条款。实现原理、构建细节与深度排障可查阅项目的 `README.md` 和 `README-docker.md`。

有踩到本文没覆盖的坑，欢迎带着 `docker logs` 的输出来留言，一起把这份教程补完整。

---

## 参考链接

**Mixly / MixSuite 官方**

- [Mixly 米思齐官网](https://mixly.cn) —— 官方运行包与各架构版本的获取入口，请认准官方渠道
- [MixIO 服务端源码](https://gitee.com/mixly2/mixio) —— 官方服务端项目

**本项目 mixly-docker**

- [GitHub 仓库](https://github.com/RealKiro/mixly-docker) —— 第 3 步 Star / Fork 的入口
- [README.md](https://github.com/RealKiro/mixly-docker/blob/main/README.md) —— 完整部署说明、安全加固、反向代理与 FAQ
- [README-docker.md](https://github.com/RealKiro/mixly-docker/blob/main/README-docker.md) —— 实现原理、镜像构建细节与深度排障
- [docker-compose.yml](https://github.com/RealKiro/mixly-docker/blob/main/docker-compose.yml) —— 第 5 步使用的配置文件
- [.env.example](https://github.com/RealKiro/mixly-docker/blob/main/.env.example) —— 切换到自己 Fork 镜像时的模板
- [docker-ci 工作流](https://github.com/RealKiro/mixly-docker/actions/workflows/ci.yml) —— 第 3 步自动构建多架构镜像的流水线

**用到的工具与文档**

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) —— Windows / macOS 安装；群晖请用 DSM 套件中心的 Container Manager
- [Docker Compose 文档](https://docs.docker.com/compose/) —— `docker compose up -d`、`${VAR:-default}` 变量插值
- [GitHub Actions 文档](https://docs.github.com/en/actions) —— Fork 后启用工作流、手动触发 Run workflow
- [GitHub Packages / GHCR 文档](https://docs.github.com/en/packages) —— 把镜像可见性改为 Public、管理 Packages

> 官方运行包的网盘地址与提取码以 [Mixly 官网](https://mixly.cn) 公布为准，本文不放第三方转载链接。

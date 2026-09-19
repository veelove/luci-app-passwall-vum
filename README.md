# PassWall 构建工具

为 iStoreOS 构建 PassWall 安装包的工具，支持本地 Docker 构建和 GitHub Actions。

## 快速开始

### 前置要求

- Docker 已安装并运行
- Git (可选)

### 本地构建

```bash
# 1. 克隆仓库 (如果还没有)
cd /path/to/yt

# 2. 构建默认配置 (x86_64)
make build-docker

# 3. 构建其他架构
make build-docker TARGET_ARCH=aarch64_generic

# 4. 查看所有可用选项
make help
```

## 构建参数

| 参数 | 默认值 | 可选值 | 说明 |
|------|--------|--------|------|
| `TARGET_ARCH` | `x86_64` | `x86_64`, `aarch64_cortex-a53`, `aarch64_generic` | 目标设备架构 |
| `SDK_VERSION` | `25.12.5` | `23.05.5` / `24.10.6` / `25.12.5` 等 | SDK 版本标记;主版本决定包格式 (23.x → ipk,24.10+/25 → apk) |
| `OPENSSL_TAG` | `libopenssl` | `libopenssl_1.1` (旧版) | OpenSSL 标签;OpenWrt 25 主线统一为 OpenSSL 3 |
| `BUILD_OPTION` | `standard` | `minimal`, `standard`, `full` | 构建选项 |

### SDK / 包格式对照

| SDK 版本 | 包格式 | 包管理器 | OpenSSL |
|----------|--------|----------|---------|
| 23.05.x 及更早 | `.ipk` | `opkg` | `libopenssl_1.1` |
| 24.10.x | `.apk` | `apk` (opkg 兼容) | `libopenssl` |
| **25.00.0** (默认) | `.apk` | `apk` (opkg 兼容) | `libopenssl` |

## 使用方法

### 1. 使用 Docker 构建 (推荐)

```bash
# 默认 x86_64 构建
make build-docker

# 自定义参数构建
make build-docker TARGET_ARCH=aarch64_generic SDK_VERSION=22.03.7
```

### 2. 使用 Docker Compose

```bash
make build-compose
```

### 3. 直接本地构建 (需先安装依赖)

```bash
# 安装依赖 (Ubuntu/Debian)
sudo apt-get install makeself unzip curl jq

# 直接构建
make build
```

### 4. GitHub Actions 构建

将 `.github/workflows/build-passwall.yml` 推送到你的仓库，然后：
- 在 GitHub 仓库页面点击 "Actions"
- 选择 "Build PassWall for iStoreOS"
- 点击 "Run workflow" 按钮
- 选择目标架构并运行

## 构建产物

构建完成后，安装包位于：
```
artifact/installer/
├── PassWall_26.5.11_x86_64_all_sdk_25.00.0.run  # 自解压安装包 (apk)
└── version.txt  # 版本信息
```

> 老版本 (OpenWrt 23.x) 构建时文件名后缀为 `_sdk_23.05.5.run`,包内使用 `.ipk`。

## 在 iStoreOS / OpenWrt 上安装

1. 将 `.run` 文件上传到路由器
2. 执行安装：
```bash
chmod +x PassWall_26.5.11_x86_64_all_sdk_25.00.0.run
./PassWall_26.5.11_x86_64_all_sdk_25.00.0.run
```
3. 安装完成后，在 LuCI 界面访问：**服务 → PassWall**

> 同一个 `.run` 在 OpenWrt 23.x (ipk/opkg) 与 24.10+/25.x (apk/apk) 上均可运行,脚本会根据构建时记录的包格式自动选择正确的包管理器。

## 项目结构

```
.
├── README.md                      # 本文档
├── build-passwall.yml            # GitHub Actions 工作流
├── build.sh                      # 构建脚本
├── make-ipk.sh                   # IPK 打包工具
├── Dockerfile                    # Docker 构建环境
├── docker-compose.yml            # Docker Compose 配置
├── Makefile                      # Make 命令入口
├── depends/                      # 依赖包目录 (23个包)
├── artifact/installer/           # 构建产物目录
└── ...
```

## make-ipk.sh 打包工具说明

`make-ipk.sh` 是一个用于自动从 GitHub 下载最新预编译二进制文件并打包成 OpenWrt/LEDE IPK 格式的工具。

### 支持的包

- **xray**: Xray-core 代理工具
- **hysteria**: Hysteria 代理工具
- **geoview**: GeoView 工具
- **sing-box**: Sing-box 代理工具

### 使用方法

#### 1. 打包单个包

```bash
# 打包 xray
./make-ipk.sh xray

# 打包 hysteria
./make-ipk.sh hysteria

# 打包 geoview
./make-ipk.sh geoview

# 打包 sing-box
./make-ipk.sh sing-box
```

#### 2. 全面打包所有包

```bash
# 一次性打包所有支持的包
./make-ipk.sh all
```

#### 3. 指定输出目录

```bash
# 打包到指定目录（例如 depends/）
./make-ipk.sh xray ./depends

# 全面打包到指定目录
./make-ipk.sh all ./depends
```

### 工作原理

1. 自动从 GitHub Releases 页面获取最新版本号
2. 下载对应架构的预编译二进制文件（默认 x86_64）
3. 自动检测二进制文件架构
4. 构建标准 IPK 包格式（包含 control.tar.gz、data.tar.gz、debian-binary）
5. 输出到指定目录

### 输出格式

默认生成 OpenWrt 24.10+/25.x 的 `.apk` 包;旧 OpenWrt 23.x 可传第三个参数 `ipk`。

命名格式：`{包名}_{版本号}_{架构}.{apk|ipk}`

例如：
- `xray_26.5.9_x86_64.apk`
- `hysteria_2.9.1_x86_64.ipk` (传入 ipk 参数时)

## 依赖包说明

安装包中包含完整的 23 个 PassWall 依赖包：
- chinadns-ng
- dns2socks
- **geoview** ([snowie2000/geoview](https://github.com/snowie2000/geoview))
- **hysteria** ([apernet/hysteria](https://github.com/apernet/hysteria))
- ipt2socks
- microsocks
- naiveproxy
- shadow-tls
- shadowsocks-rust (sslocal/ssserver)
- shadowsocksr-libev (ssr-local/ssr-redir/ssr-server)
- simple-obfs-client
- **sing-box** ([SagerNet/sing-box](https://github.com/SagerNet/sing-box))
- tcping
- trojan-plus
- tuic-client
- v2ray-geoip, v2ray-geosite, v2ray-plugin
- **xray-core** ([XTLS/Xray-core](https://github.com/XTLS/Xray-core)), xray-plugin

## 组件上游源

| 组件 | 上游源 |
|------|--------|
| Geoview | https://github.com/snowie2000/geoview |
| Xray-core | https://github.com/XTLS/Xray-core |
| Sing-Box | https://github.com/SagerNet/sing-box |
| Hysteria | https://github.com/apernet/hysteria |
| PassWall | https://github.com/Openwrt-Passwall/openwrt-passwall |

## 清理

```bash
make clean
```

## 常见问题

### Q: 为什么需要 Docker？
A: 为了确保构建环境一致，并且 Docker 镜像已预安装所有构建工具 (makeself, jq, curl 等)。

### Q: GitHub Actions 构建需要配置吗？
A: 不需要，只要将代码推送到 GitHub 仓库即可。工作流会自动运行。

### Q: 我想为其他架构构建怎么办？
A: 修改 `TARGET_ARCH` 参数：
```bash
make build-docker TARGET_ARCH=aarch64_generic
```

## 更新日志

- **2026-09-19**: 支持 OpenWrt 25 主线 (apk/apk),默认 SDK 切换到 25.00.0;OpenWrt 23.x (ipk/opkg) 仍可显式构建
- **2026-05-11**: 修复仓库地址 (xiaorouji → Openwrt-Passwall)，添加完整依赖包
- **2025-08-30**: 解决安装过程中丢失登录状态问题

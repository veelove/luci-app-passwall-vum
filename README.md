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
| `SDK_VERSION` | `22.03.7` | - | SDK 版本标记 |
| `OPENSSL_TAG` | `libopenssl_1.1` | - | OpenSSL 标签 |
| `BUILD_OPTION` | `standard` | `minimal`, `standard`, `full` | 构建选项 |

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
├── PassWall_26.5.3_x86_64_all_sdk_22.03.7.run  # 自解压安装包 (72MB)
└── version.txt  # 版本信息
```

## 在 iStoreOS 上安装

1. 将 `.run` 文件上传到路由器
2. 执行安装：
```bash
chmod +x PassWall_26.5.3_x86_64_all_sdk_22.03.7.run
./PassWall_26.5.3_x86_64_all_sdk_22.03.7.run
```
3. 安装完成后，在 LuCI 界面访问：**服务 → PassWall**

## 项目结构

```
.
├── README.md                      # 本文档
├── build-passwall.yml            # GitHub Actions 工作流
├── build.sh                      # 构建脚本
├── Dockerfile                    # Docker 构建环境
├── docker-compose.yml            # Docker Compose 配置
├── Makefile                      # Make 命令入口
├── depends/                      # 依赖包目录 (23个包)
├── artifact/installer/           # 构建产物目录
└── ...
```

## 依赖包说明

安装包中包含完整的 23 个 PassWall 依赖包：
- chinadns-ng
- dns2socks
- geoview
- hysteria
- ipt2socks
- microsocks
- naiveproxy
- shadow-tls
- shadowsocks-rust (sslocal/ssserver)
- shadowsocksr-libev (ssr-local/ssr-redir/ssr-server)
- simple-obfs-client
- sing-box
- tcping
- trojan-plus
- tuic-client
- v2ray-geoip, v2ray-geosite, v2ray-plugin
- xray-core, xray-plugin

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

- **2026-05-11**: 修复仓库地址 (xiaorouji → Openwrt-Passwall)，添加完整依赖包
- **2025-08-30**: 解决安装过程中丢失登录状态问题

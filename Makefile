.PHONY: build build-docker build-compose clean help

# 默认参数
TARGET_ARCH ?= x86_64
# 默认适配 OpenWrt 25 主线（OpenWrt 24.10+ 已切换到 apk 格式）
# 如需构建旧版 (OpenWrt 23.x)，请显式指定 SDK_VERSION=23.05.5 OPENSSL_TAG=libopenssl_1.1
SDK_VERSION ?= 25.00.0
# OpenWrt 25 主线 OpenWrt 默认使用 OpenSSL 3 (libopenssl),不再区分 libopenssl_1.1
OPENSSL_TAG ?= libopenssl
BUILD_OPTION ?= standard

help:
	@echo "PassWall 构建工具 (支持 OpenWrt 23.x ipk 与 24.10+/25.x apk)"
	@echo ""
	@echo "可用命令:"
	@echo "  make build              - 直接运行构建 (本机需安装依赖)"
	@echo "  make build-docker       - 使用 Docker 构建"
	@echo "  make build-compose      - 使用 docker-compose 构建"
	@echo "  make clean              - 清理构建产物"
	@echo ""
	@echo "可用变量:"
	@echo "  TARGET_ARCH             - 目标架构 (x86_64, aarch64_cortex-a53, aarch64_generic)"
	@echo "  SDK_VERSION             - SDK 版本 (默认 25.00.0;旧版可设 23.05.5 / 24.10.6)"
	@echo "  OPENSSL_TAG             - OpenSSL 标签 (默认 libopenssl;旧版用 libopenssl_1.1)"
	@echo "  BUILD_OPTION            - 构建选项 (minimal, standard, full)"
	@echo ""
	@echo "示例:"
	@echo "  make build-docker                                          # 默认:OpenWrt 25.x (apk)"
	@echo "  make build-docker SDK_VERSION=24.10.6 OPENSSL_TAG=libopenssl_1.1"
	@echo "  make build-docker TARGET_ARCH=aarch64_generic              # aarch64 通用(24.10+)"

build:
	chmod +x build.sh
	./build.sh $(TARGET_ARCH) $(SDK_VERSION) $(OPENSSL_TAG) $(BUILD_OPTION)

build-docker:
	docker build -t passwall-builder .
	docker run --rm \
		-v $(shell pwd):/build \
		-w /build \
		-e TARGET_ARCH=$(TARGET_ARCH) \
		-e SDK_VERSION=$(SDK_VERSION) \
		-e OPENSSL_TAG=$(OPENSSL_TAG) \
		-e BUILD_OPTION=$(BUILD_OPTION) \
		-e GITHUB_TOKEN=$(GITHUB_TOKEN) \
		passwall-builder \
		bash -c "chmod +x build.sh && ./build.sh $(TARGET_ARCH) $(SDK_VERSION) $(OPENSSL_TAG) $(BUILD_OPTION)"

build-compose:
	docker-compose up --build

clean:
	rm -rf artifact/ passwall-ipk/ staging/ cores/
	rm -f *.run *.zip *.tar.gz *.apk version.txt

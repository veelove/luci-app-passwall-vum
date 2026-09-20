#!/bin/bash
set -e

# 默认参数（兼容 OpenWrt 22.03 / 23.05-24.10 / iStoreOS 25.x、OpenWrt 25.12+）
TARGET_ARCH=${1:-x86_64}
SDK_VERSION=${2:-25.05.0}
OPENSSL_TAG=${3:-libopenssl}
BUILD_OPTION=${4:-standard}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

# 根据 SDK_VERSION 自动选择 OpenSSL 标记（22.03 用 libopenssl_1.1，新版本用 libopenssl）
case "$SDK_VERSION" in
    22.03*|19.07*|18.06*)
        [ "$OPENSSL_TAG" = "libopenssl" ] && OPENSSL_TAG="libopenssl_1.1"
        ;;
    *)
        [ "$OPENSSL_TAG" = "libopenssl_1.1" ] && OPENSSL_TAG="libopenssl"
        ;;
esac
export OPENSSL_TAG

echo "========================================="
echo "PassWall 构建脚本"
echo "目标架构: $TARGET_ARCH"
echo "SDK 版本: $SDK_VERSION"
echo "OpenSSL: $OPENSSL_TAG"
echo "========================================="

# 准备环境
echo "准备环境..."
rm -rf artifact/installer staging
mkdir -p passwall-ipk artifact/installer staging

# 检查 passwall-ipk 目录是否为空，如果是则下载 IPK/APK 包
if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
    echo "passwall-ipk 目录为空，正在从上游 Release 下载 luci-app-passwall 和语言包..."

    curl_gh() {
        if [ -n "$GITHUB_TOKEN" ]; then
            curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
        else
            curl -fsSL "$@"
        fi
    }

    # 获取最新版本信息
    API_LATEST="https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest"
    RELEASE_DATA="$(curl_gh "$API_LATEST" 2>/dev/null || true)"
    RELEASE_TAG="$(echo "$RELEASE_DATA" | jq -r .tag_name 2>/dev/null || true)"
    if [ -z "$RELEASE_TAG" ] || [ "$RELEASE_TAG" = "null" ]; then
        echo "获取 latest release 失败，尝试从所有 releases 获取..."
        RELEASE_DATA="$(curl_gh "https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases" 2>/dev/null || true)"
        RELEASE_TAG="$(echo "$RELEASE_DATA" | jq -r '.[0].tag_name' 2>/dev/null || true)"
    fi
    [ -z "$RELEASE_TAG" ] || [ "$RELEASE_TAG" = "null" ] && RELEASE_TAG="26.9.16-1"
    echo "检测到的版本: $RELEASE_TAG"

    # 按 SDK 版本选择资产匹配规则：
    #  22.03*          -> 22.03- 前缀 ipk
    #  23.05* / 24.10* -> 23.05-24.10 前缀 ipk
    #  25.* / 其它     -> 25.12+ 前缀 apk
    case "$SDK_VERSION" in
        22.03*|19.07*|18.06*)
            APP_PAT='^22\.03-.*luci-app-passwall.*\.ipk$'
            I18N_PAT='^22\.03-.*luci-i18n-passwall-zh-cn.*\.ipk$'
            ;;
        23.05*|24.10*)
            APP_PAT='^23\.05-24\.10.*luci-app-passwall.*\.ipk$'
            I18N_PAT='^23\.05-24\.10.*luci-i18n-passwall-zh-cn.*\.ipk$'
            ;;
        *)
            APP_PAT='^25\.12\+.*luci-app-passwall.*\.apk$'
            I18N_PAT='^25\.12\+.*luci-i18n-passwall-zh-cn.*\.apk$'
            ;;
    esac

    APP_URL="$(echo "$RELEASE_DATA" | jq -r --arg pat "$APP_PAT" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -n 1)"
    I18N_URL="$(echo "$RELEASE_DATA" | jq -r --arg pat "$I18N_PAT" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -n 1)"

    if [ -z "$APP_URL" ] || [ "$APP_URL" = "null" ]; then
        echo "警告: SDK_VERSION=$SDK_VERSION 未匹配到对应格式，回退到通用匹配..."
        APP_URL="$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("luci-app-passwall.*\\.(ipk|apk)$")) | .browser_download_url' | head -n 1)"
        I18N_URL="$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("luci-i18n-passwall-zh-cn.*\\.(ipk|apk)$")) | .browser_download_url' | head -n 1)"
    fi

    echo "尝试下载 APP: $APP_URL"
    if [ -n "$APP_URL" ] && [ "$APP_URL" != "null" ] && curl -fL "$APP_URL" -o "passwall-ipk/$(basename "$APP_URL")"; then
        echo "成功下载 APP"
    else
        echo "错误: 无法下载 luci-app-passwall 包"
        exit 1
    fi

    echo "尝试下载 I18N: $I18N_URL"
    if [ -n "$I18N_URL" ] && [ "$I18N_URL" != "null" ] && curl -fL "$I18N_URL" -o "passwall-ipk/$(basename "$I18N_URL")"; then
        echo "成功下载 I18N"
    else
        echo "警告: 无法下载中文语言包，将继续构建但不包含语言包"
    fi

    echo "已下载文件："
    ls -lh passwall-ipk/

    # 验证至少成功下载了 APP 包
    if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
        echo "错误: passwall-ipk 目录仍然为空"
        exit 1
    fi
else
    echo "使用本地已有的 luci 包..."
fi

# 获取日期
BUILD_DATE=$(date)

# 架构映射
case "$TARGET_ARCH" in
  x86_64) ARCH_MAP="x86_64" ;;
  aarch64_cortex-a53) ARCH_MAP="aarch64_cortex-a53" ;;
  *) ARCH_MAP="aarch64_generic" ;;
esac
echo "架构映射: $ARCH_MAP"

# 定位 luci 包（兼容 ipk 与 apk）
echo "定位 luci 包..."
find_app() { find passwall-ipk -type f -name '*luci-app-passwall*' \( -name '*.ipk' -o -name '*.apk' \) | head -n1 || true; }
find_i18n() { find passwall-ipk -type f -name '*luci-i18n-passwall-zh-cn*' \( -name '*.ipk' -o -name '*.apk' \) | head -n1 || true; }

APP_PKG="$(find_app)"
I18N_PKG="$(find_i18n)"

if [ -z "$APP_PKG" ]; then
  echo "错误: 未找到 luci-app-passwall 包"
  exit 1
fi

echo "定位到："
echo "APP: $APP_PKG"
echo "I18N: $I18N_PKG"

# 解析版本号（兼容 ipk：22.03-_luci-app-passwall_26.9.16_all.ipk；apk：25.12+_luci-app-passwall-26.9.16-r1.apk）
APP_PATH="$APP_PKG"
BASE="$(basename "$APP_PATH")"
APPVER="$(echo "$BASE" | sed -E 's/^.*luci-app-passwall[-_]([0-9.]+)[^_]*\.(ipk|apk)$/\1/')"
if [ -z "${APPVER:-}" ] || [ "$APPVER" = "$BASE" ]; then
  APPVER="26.9.16"
fi
echo "APP 版本: $APPVER"

# 构建 Makeself
echo "构建安装包..."
STAGING_ROOT="staging"
STAGING_DIR="$STAGING_ROOT/$ARCH_MAP"
DEP_DIR="$STAGING_DIR/depends"
rm -rf "$STAGING_DIR"
mkdir -p "$DEP_DIR"

APP_BASE="$(basename "$APP_PKG")"
EXT="${APP_BASE##*.}"
cp -f "$APP_PKG" "$STAGING_DIR/$APP_BASE"
# 固定文件名供 install.sh 探测（保留原扩展名 ipk/apk）
cp -f "$APP_PKG" "$STAGING_DIR/luci-app-passwall.$EXT"

if [ -n "$I18N_PKG" ]; then
  I18N_BASE="$(basename "$I18N_PKG")"
  I18N_EXT="${I18N_BASE##*.}"
  cp -f "$I18N_PKG" "$STAGING_DIR/$I18N_BASE"
  cp -f "$I18N_PKG" "$STAGING_DIR/luci-i18n-passwall-zh-cn.$I18N_EXT"
fi

# 复制本地的 depends 目录（包含完整依赖）
echo "复制依赖包..."
if [ -d depends ]; then
  cp -r depends/* "$DEP_DIR/"
fi

# 生成安装脚本
cat > "$STAGING_DIR/install.sh" <<'EOF'
#!/bin/sh
set -e

# 由构建脚本写入的 SDK 版本标记，用于运行时选择依赖与刷新策略
SDK_VERSION="$(cat .sdk_version 2>/dev/null || echo @SDK_VERSION@)"

# 探测包管理器：iStoreOS 25 / OpenWrt 24.10+ 用 apk，OpenWrt 22.03/23.05 用 opkg
PKG_MGR=""
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
fi
echo "检测到包管理器: ${PKG_MGR:-未找到}"

# 检查依赖是否已安装（按包管理器）
is_installed() {
    dep="$1"
    if [ "$PKG_MGR" = "apk" ]; then
        apk info -e "$dep" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -q "^$dep "
    fi
}

# 安装依赖（按包管理器）
install_dep() {
    dep="$1"
    if [ "$PKG_MGR" = "apk" ]; then
        if ! apk add -q --force-overwrite --clean-protected --allow-untrusted "$dep"; then
            echo "警告: 无法安装 $dep"
            return 1
        fi
    elif [ "$PKG_MGR" = "opkg" ]; then
        if ! opkg install "$dep"; then
            echo "警告: 无法安装 $dep"
            return 1
        fi
    else
        echo "错误: 未找到包管理器，无法安装 $dep"
        return 1
    fi
}

# 检查并安装 PassWall 必需依赖
check_passwall_deps() {
    echo "检查 PassWall 必需依赖..."

    if [ "$PKG_MGR" = "apk" ]; then
        # apk 幂等：逐个安装，已安装的包自动跳过（返回 0 且无输出），
        # 只有真正失败时才打印警告，避免把"已装好"误报成"缺失依赖"。
        local deps="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra ip-full ipset iptables-mod-extra iptables-mod-filter"
        for dep in $deps; do
            if ! apk add -q --force-overwrite --clean-protected --allow-untrusted "$dep"; then
                echo "警告: 无法安装 $dep，可能需要手动处理"
            fi
        done
    else
        # iptables 透明代理模块
        local iptables_deps="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra"
        local kernel_deps="kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra"

        for dep in $iptables_deps $kernel_deps; do
            if ! is_installed "$dep"; then
                echo "安装缺失依赖: $dep"
                install_dep "$dep" || echo "警告: 无法安装 $dep，可能需要手动处理"
            fi
        done

        # 其他常用依赖
        local other_deps="ip-full ipset iptables-mod-extra iptables-mod-filter"
        for dep in $other_deps; do
            if ! is_installed "$dep"; then
                echo "安装推荐依赖: $dep"
                install_dep "$dep" || true
            fi
        done
    fi
}

# 温和地刷新 LuCI 缓存（不重启服务，避免丢失登录状态）
refresh_luci() {
  # 清理缓存文件
  rm -f /tmp/luci-indexcache 2>/dev/null || true
  rm -rf /tmp/luci-modulecache/* 2>/dev/null || true

  # 优先使用 luci-reload（如果可用）
  if command -v luci-reload >/dev/null 2>&1; then
    echo "使用 luci-reload 刷新 LuCI..."
    luci-reload 2>/dev/null || true
  else
    # 使用 Lua 直接重建索引（兼容不同版本函数名）
    if command -v lua >/dev/null 2>&1; then
      echo "使用 Lua 重建 LuCI 索引..."
      lua -e 'local ok,d=pcall(require,"luci.dispatcher"); if ok and d then if d.rebuild_index then d.rebuild_index() elseif d.createindex then d.createindex() end end' 2>/dev/null || true
    fi
    # 使用 ucode 重建索引（iStoreOS 25 / OpenWrt 24.10+）
    if command -v ucode >/dev/null 2>&1; then
      echo "使用 ucode 重建 LuCI 索引..."
      ucode -e 'require("luci.dispatcher").rebuild_index?.()' 2>/dev/null || true
    fi

    # 温和地重载 HTTP 服务（不重启）
    if [ -x /etc/init.d/uhttpd ]; then
      echo "重载 uhttpd..."
      /etc/init.d/uhttpd reload 2>/dev/null || true
    fi
    if [ -x /etc/init.d/nginx ]; then
      echo "重载 nginx..."
      /etc/init.d/nginx reload 2>/dev/null || true
    fi
    if [ -x /etc/init.d/rpcd ]; then
      echo "重载 rpcd..."
      /etc/init.d/rpcd reload 2>/dev/null || true
    fi
  fi

  # 确保文件系统同步
  sync
}

# 使用固定文件名（保留扩展名 ipk/apk，由构建脚本按 SDK 版本决定）
APP_PKG="luci-app-passwall.ipk"
I18N_PKG="luci-i18n-passwall-zh-cn.ipk"
if [ "$PKG_MGR" = "apk" ]; then
  [ -f "luci-app-passwall.apk" ] && APP_PKG="luci-app-passwall.apk"
  [ -f "luci-i18n-passwall-zh-cn.apk" ] && I18N_PKG="luci-i18n-passwall-zh-cn.apk"
fi

if [ ! -f "$APP_PKG" ]; then
  echo "错误: 缺少 $APP_PKG"
  ls -l
  exit 1
fi

# 安装前轻度刷新
refresh_luci

# 更新软件源
if [ "$PKG_MGR" = "apk" ]; then
    apk update || { echo "apk update 失败，请检查路由器网络以及软件源。"; exit 1; }
else
    opkg update || { echo "更新软件源列表错误，请检查路由器网络以及软件源。"; exit 1; }
fi

# 安装基础依赖（容错，按 SDK 版本分支）
echo "安装基础依赖..."
case "$SDK_VERSION" in
    22.03*|19.07*|18.06*)
        # 旧版 OpenWrt / iStoreOS 22.03：Lua + luci-compat
        for dep in luci-compat luci-lib-jsonc libuci-lua; do
            install_dep "$dep" 2>/dev/null || true
        done
        ;;
    *)
        # iStoreOS 25 / OpenWrt 24.10+：ucode + rpcd，无 luci-compat
        for dep in luci-lib-jsonc libuci-lua ucode ucode-mod-lua; do
            install_dep "$dep" 2>/dev/null || true
        done
        ;;
esac

# 检查并安装 PassWall 必需依赖
check_passwall_deps

# 安装 depends 下的依赖包（opkg 装 ipk；apk 装 apk，无 apk 则跳过）
if [ -d depends ]; then
  echo "安装依赖包..."
  if [ "$PKG_MGR" = "apk" ]; then
    if ls depends/*.apk >/dev/null 2>&1; then
      apk add -q --force-overwrite --clean-protected --allow-untrusted depends/*.apk || true
    fi
  elif ls depends/*.ipk >/dev/null 2>&1; then
    opkg install depends/*.ipk || true
  fi
fi

# 额外常用组件（容错）
echo "安装额外组件..."
if [ "$PKG_MGR" = "apk" ]; then
    apk add -q --force-overwrite --clean-protected --allow-untrusted haproxy shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server 2>/dev/null || true
else
    opkg install haproxy shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server 2>/dev/null || true
fi

# 始终强制重装，避免版本判断带来的不确定性
echo "安装 PassWall 主程序..."
if [ "$PKG_MGR" = "apk" ]; then
    apk add -q --force-overwrite --clean-protected --allow-untrusted "$APP_PKG" || exit 1
else
    opkg install "$APP_PKG" --force-reinstall || exit 1
fi

# 安装中文语言包（仅本地文件）
if [ -f "$I18N_PKG" ]; then
  echo "安装中文语言包: $I18N_PKG"
  if [ "$PKG_MGR" = "apk" ]; then
    apk add -q --force-overwrite --clean-protected --allow-untrusted "$I18N_PKG" || true
  else
    opkg install "$I18N_PKG" || true
  fi
else
  echo "未发现本地中文语言包，跳过安装"
fi

# 启用并启动服务
if [ -x /etc/init.d/passwall ]; then
  echo "启用 PassWall 服务..."
  /etc/init.d/passwall enable 2>/dev/null || true
  /etc/init.d/passwall start 2>/dev/null || true
fi

# 重载防火墙（不重启）
if [ -x /etc/init.d/firewall ]; then
  echo "重载防火墙规则..."
  /etc/init.d/firewall reload 2>/dev/null || true
fi

# 安装后轻度刷新
refresh_luci

# 验证安装结果（兼容 lua 与 ucode 控制器）
if [ -f /usr/lib/lua/luci/controller/passwall.lua ] || \
   ls /usr/lib/lua/luci/controller/passwall/*.lua >/dev/null 2>&1 || \
   find /usr/lib/lua/luci /usr/share/ucode/luci -name "*passwall*" -type f >/dev/null 2>&1; then
  echo "✓ 安装完成！请在 LuCI 界面 服务→PassWall 查看。"
  echo "  如果菜单未显示，请刷新浏览器或重新登录 LuCI。"
  exit 0
else
  echo "! 警告：未检测到 PassWall 控制器文件，可能需刷新浏览器或重新登录 LuCI。"
  exit 0
fi
EOF
chmod +x "$STAGING_DIR/install.sh"

# 把占位符 @SDK_VERSION@ 替换为构建时的 SDK 版本（兼容 macOS BSD sed）
if sed --version >/dev/null 2>&1; then
    sed -i "s|@SDK_VERSION@|$SDK_VERSION|g" "$STAGING_DIR/install.sh"
else
    sed -i '' "s|@SDK_VERSION@|$SDK_VERSION|g" "$STAGING_DIR/install.sh"
fi

OUTPUT="PassWall_${APPVER}_${ARCH_MAP}_all_sdk_${SDK_VERSION}.run"
LABEL="PassWall_${APPVER}_with_sdk_${SDK_VERSION}_${OPENSSL_TAG}"
makeself --gzip --nox11 "$STAGING_DIR" "$OUTPUT" "$LABEL" ./install.sh

echo "PassWall(luci-app)版本: $APPVER" > version.txt
echo "上游Release Tag: $APPVER-r1" >> version.txt
echo "SDK版本: $SDK_VERSION" >> version.txt
echo "OpenSSL标记: $OPENSSL_TAG" >> version.txt
echo "构建时间: $BUILD_DATE" >> version.txt
echo "目标架构: $TARGET_ARCH" >> version.txt
echo "构建选项: $BUILD_OPTION" >> version.txt

rm -rf artifact/installer/*
mv -f "$OUTPUT" artifact/installer/
mv -f version.txt artifact/installer/

echo "========================================="
echo "构建成功！"
echo "构建产物："
ls -lh artifact/installer/
echo "========================================="

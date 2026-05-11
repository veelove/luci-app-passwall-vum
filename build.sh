#!/bin/bash
set -e

# 默认参数
TARGET_ARCH=${1:-x86_64}
SDK_VERSION=${2:-22.03.7}
OPENSSL_TAG=${3:-libopenssl_1.1}
BUILD_OPTION=${4:-standard}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

echo "========================================="
echo "PassWall 构建脚本"
echo "目标架构: $TARGET_ARCH"
echo "SDK 版本: $SDK_VERSION"
echo "OpenSSL: $OPENSSL_TAG"
echo "========================================="

# 准备环境
echo "准备环境..."
rm -rf artifact/installer passwall-ipk staging
mkdir -p passwall-ipk artifact/installer staging

# 获取日期
BUILD_DATE=$(date)

# 架构映射
case "$TARGET_ARCH" in
  x86_64) ARCH_MAP="x86_64" ;;
  aarch64_cortex-a53) ARCH_MAP="aarch64_cortex-a53" ;;
  *) ARCH_MAP="aarch64_generic" ;;
esac
echo "架构映射: $ARCH_MAP"

# 获取最新版本
echo "获取最新版本..."
curl_gh() { 
  if [ -n "$GITHUB_TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  fi
}

API_LATEST="https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest"
RELEASE_DATA=$(curl_gh "$API_LATEST" || true)
LATEST_VERSION=$(echo "$RELEASE_DATA" | jq -r .tag_name || true)
[ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ] && LATEST_VERSION="26.5.3-1"
echo "最新版本: $LATEST_VERSION"

# 从 GitHub release 中找到合适的 luci 包
echo "从 GitHub 下载 luci 包..."
APP_URL=$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("luci-app-passwall.*\\.ipk$")) | .browser_download_url' | head -n 1)
I18N_URL=$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("luci-i18n-passwall-zh-cn.*\\.ipk$")) | .browser_download_url' | head -n 1)

echo "下载 APP: $APP_URL"
curl -fL "$APP_URL" -o passwall-ipk/$(basename "$APP_URL")
echo "下载 I18N: $I18N_URL"
curl -fL "$I18N_URL" -o passwall-ipk/$(basename "$I18N_URL")

# 定位 luci 包
echo "定位 luci 包..."
find_app() { find passwall-ipk -type f -name '*luci-app-passwall*.ipk' | head -n1 || true; }
find_i18n() { find passwall-ipk -type f -name '*luci-i18n-passwall-zh-cn*.ipk' | head -n1 || true; }

APP_PKG="$(find_app)"; I18N_PKG="$(find_i18n)"

if [ -z "$APP_PKG" ]; then
  echo "未找到 luci-app-passwall 顶层包"
  exit 1
fi
if [ -z "$I18N_PKG" ]; then
  echo "未找到 zh-cn 语言包"
  exit 1
fi

echo "定位到:"
echo "APP: $APP_PKG"
echo "I18N: $I18N_PKG"

# 解析版本号
APP_PATH="$APP_PKG"
BASE="$(basename "$APP_PATH")"
APPVER="$(echo "$BASE" | sed -E 's/^.*luci-app-passwall_([^_]+).*\.ipk$/\1/')"
if [ -z "${APPVER:-}" ] || [ "$APPVER" = "$BASE" ]; then
  LV="$LATEST_VERSION"; APPVER="${LV%%-*}"
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
I18N_BASE="$(basename "$I18N_PKG")"
cp -f "$APP_PKG" "$STAGING_DIR/$APP_BASE"
cp -f "$APP_PKG" "$STAGING_DIR/luci-app-passwall.ipk"
cp -f "$I18N_PKG" "$STAGING_DIR/$I18N_BASE"
cp -f "$I18N_PKG" "$STAGING_DIR/luci-i18n-passwall-zh-cn.ipk"

# 复制本地的 depends 目录（从老版本提取出来的）
if [ -d depends ]; then
  echo "复制依赖包..."
  cp -r depends/* "$DEP_DIR/"
fi

cat > "$STAGING_DIR/install.sh" <<'EOF'
#!/bin/sh
set -e

# 检查并安装 PassWall 必需依赖
check_passwall_deps() {
  echo "检查 PassWall 必需依赖..."
  
  # iptables 透明代理模块
  local iptables_deps="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra"
  local kernel_deps="kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra"
  
  for dep in $iptables_deps $kernel_deps; do
    if ! opkg list-installed | grep -q "^$dep "; then
      echo "安装缺失依赖: $dep"
      opkg install "$dep" 2>/dev/null || echo "警告: 无法安装 $dep，可能需要手动处理"
    fi
  done
  
  # 其他常用依赖
  local other_deps="ip-full ipset iptables-mod-extra iptables-mod-filter"
  for dep in $other_deps; do
    if ! opkg list-installed | grep -q "^$dep "; then
      echo "安装推荐依赖: $dep"
      opkg install "$dep" 2>/dev/null || true
    fi
  done
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
    
    # 温和地重载 HTTP 服务（不重启）
    if [ -x /etc/init.d/uhttpd ]; then
      echo "重载 uhttpd..."
      /etc/init.d/uhttpd reload 2>/dev/null || true
    fi
    if [ -x /etc/init.d/nginx ]; then
      echo "重载 nginx..."
      /etc/init.d/nginx reload 2>/dev/null || true
    fi
  fi
  
  # 确保文件系统同步
  sync
}

# 使用固定文件名，不再通配
APP_PKG="luci-app-passwall.ipk"
I18N_PKG="luci-i18n-passwall-zh-cn.ipk"

if [ ! -f "$APP_PKG" ]; then
  echo "错误: 缺少 $APP_PKG"
  ls -l
  exit 1
fi

# 安装前轻度刷新
refresh_luci

if ! opkg update; then
  echo "更新软件源列表错误，请检查路由器网络以及软件源。"
  exit 1
fi

# 安装基础依赖（容错）
echo "安装基础依赖..."
opkg install luci-compat luci-lib-jsonc libuci-lua 2>/dev/null || true

# 检查并安装 PassWall 必需依赖
check_passwall_deps

# 安装 depends 下的 ipk（若存在）
if [ -d depends ] && ls depends/*.ipk >/dev/null 2>&1; then
  echo "安装依赖包..."
  opkg install depends/*.ipk || true
fi

# 额外常用组件（容错）
echo "安装额外组件..."
opkg install haproxy shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server 2>/dev/null || true

# 始终强制重装，避免版本判断带来的不确定性
echo "安装 PassWall 主程序..."
opkg install "$APP_PKG" --force-reinstall || exit 1

# 安装中文语言包（仅本地文件）
if [ -f "$I18N_PKG" ]; then
  echo "安装中文语言包: $I18N_PKG"
  opkg install "$I18N_PKG" || true
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

# 验证依赖安装情况
echo "验证关键依赖..."
missing_deps=""
for dep in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange; do
  if ! opkg list-installed | grep -q "^$dep "; then
    missing_deps="$missing_deps $dep"
  fi
done

if [ -n "$missing_deps" ]; then
  echo "警告: 以下依赖未安装，可能影响透明代理功能:$missing_deps"
  echo "请手动执行: opkg install$missing_deps"
fi

# 验证安装结果
if [ -f /usr/lib/lua/luci/controller/passwall.lua ] || ls /usr/lib/lua/luci/controller/passwall/*.lua >/dev/null 2>&1; then
  echo "✓ 安装完成！请在 LuCI 界面 服务→PassWall 查看。"
  echo "  如果菜单未显示，请刷新浏览器或重新登录 LuCI。"
  if [ -z "$missing_deps" ]; then
    echo "  所有必需依赖已正确安装。"
  fi
  exit 0
else
  echo "! 警告：未检测到 PassWall 控制器文件，可能需刷新浏览器或重新登录 LuCI。"
  exit 0
fi
EOF
chmod +x "$STAGING_DIR/install.sh"

OUTPUT="PassWall_${APPVER}_${ARCH_MAP}_all_sdk_${SDK_VERSION}.run"
LABEL="PassWall_${APPVER}_with_sdk_${SDK_VERSION}_${OPENSSL_TAG}"
makeself --gzip --nox11 "$STAGING_DIR" "$OUTPUT" "$LABEL" ./install.sh

echo "PassWall(luci-app)版本: $APPVER" > version.txt
echo "上游Release Tag: $LATEST_VERSION" >> version.txt
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

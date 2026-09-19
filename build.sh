#!/bin/bash
set -e

# 默认参数
TARGET_ARCH=${1:-x86_64}
SDK_VERSION=${2:-25.00.0}
OPENSSL_TAG=${3:-libopenssl}
BUILD_OPTION=${4:-standard}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

echo "========================================="
echo "PassWall 构建脚本 (支持 OpenWrt 23.x ipk 与 24.10+/25.x apk)"
echo "目标架构: $TARGET_ARCH"
echo "SDK 版本: $SDK_VERSION"
echo "OpenSSL:  $OPENSSL_TAG"
echo "构建选项: $BUILD_OPTION"
echo "========================================="

# ------------------------------------------------------------------
# 根据 SDK_VERSION 判断是 .ipk (OpenWrt <= 23.x) 还是 .apk (24.10+/25)
# OpenWrt 24.10+ 官方主推 apk 格式(.apk),opkg 仍然兼容接收 .apk
# ------------------------------------------------------------------
case "$SDK_VERSION" in
    23.*|22.*|19.*|18.*|17.*|15.*)
        PKG_EXT="ipk"
        PKG_MGR="opkg"
        ;;
    *)
        PKG_EXT="apk"
        # OpenWrt 24.10+/25.x 既有 opkg 也有 apk,两者都接受 .apk,优先 apk
        PKG_MGR="apk"
        ;;
esac
echo "包格式: .$PKG_EXT  (包管理器: $PKG_MGR)"

# 准备环境
echo "准备环境..."
rm -rf artifact/installer staging cores
mkdir -p passwall-ipk artifact/installer staging cores

# 解析版本主号: 25.00.0 -> 25.00.0  / 24.10.6 -> 24.10.6  / 23.05.5 -> 23.05.5
SDK_MAJOR="$(echo "$SDK_VERSION" | cut -d. -f1)"

# 上游 luci-app-passwall asset 命名约定:
#   OpenWrt 22.03.x    -> 22.03-_luci-app-passwall_<ver>_<arch>.ipk
#   OpenWrt 23.05.x    -> 23.05-_luci-app-passwall_<ver>_<arch>.ipk
#   OpenWrt 24.10.x    -> 24.10-_luci-app-passwall_<ver>_<arch>.apk
#   OpenWrt 25.00.0    -> 25.00.0-_luci-app-passwall_<ver>_<arch>.apk
APP_PREFIX="${SDK_VERSION}-"
I18N_PREFIX="${SDK_VERSION}-"

# 检查 passwall-ipk 目录是否为空，如果是则下载 luci-app-passwall 主包
if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
    echo "passwall-ipk 目录为空,正在从上游下载 luci-app-passwall 包..."

    # 已知最近版本
    RELEASE_TAG="26.5.11-1"

    APP_FILENAME="${APP_PREFIX}_luci-app-passwall_${RELEASE_TAG%%-*}_all.${PKG_EXT}"
    I18N_FILENAME="${APP_PREFIX}_luci-i18n-passwall-zh-cn_${RELEASE_TAG%%-*}_all.${PKG_EXT}"

    APP_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${RELEASE_TAG}/${APP_FILENAME}"
    I18N_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${RELEASE_TAG}/${I18N_FILENAME}"

    echo "尝试下载 APP: $APP_URL"
    if ! curl -fL "$APP_URL" -o "passwall-ipk/$APP_FILENAME"; then
        echo "错误: 无法下载 luci-app-passwall 包,请检查 SDK_VERSION=${SDK_VERSION} 是否对应上游 asset 命名。"
        exit 1
    fi
    echo "成功下载 APP"

    echo "尝试下载 I18N: $I18N_URL"
    if curl -fL "$I18N_URL" -o "passwall-ipk/$I18N_FILENAME"; then
        echo "成功下载 I18N"
    else
        echo "警告: 无法下载中文语言包,将继续构建但不包含语言包"
    fi

    echo "已下载文件:"
    ls -lh passwall-ipk/

    if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
        echo "错误: passwall-ipk 目录仍然为空"
        exit 1
    fi
else
    echo "使用本地已有的 luci 包..."
fi

BUILD_DATE=$(date)

# 架构映射
case "$TARGET_ARCH" in
  x86_64) ARCH_MAP="x86_64" ;;
  aarch64_cortex-a53) ARCH_MAP="aarch64_cortex-a53" ;;
  *) ARCH_MAP="aarch64_generic" ;;
esac
echo "架构映射: $ARCH_MAP"

# 定位 luci 包(支持 .ipk 和 .apk 两种后缀)
echo "定位 luci 包..."
find_app()  { find passwall-ipk -type f -name '*luci-app-passwall*.ipk' -o -name '*luci-app-passwall*.apk' 2>/dev/null | head -n1 || true; }
find_i18n() { find passwall-ipk -type f -name '*luci-i18n-passwall-zh-cn*.ipk' -o -name '*luci-i18n-passwall-zh-cn*.apk' 2>/dev/null | head -n1 || true; }

APP_PKG="$(find_app)"
I18N_PKG="$(find_i18n)"

if [ -z "$APP_PKG" ]; then
  echo "错误: 未找到 luci-app-passwall 包"
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
    APPVER="$(echo "$BASE" | sed -E 's/^.*luci-app-passwall_([^_]+).*\.apk$/\1/')"
fi
if [ -z "${APPVER:-}" ] || [ "$APPVER" = "$BASE" ]; then
  APPVER="25.11.15"
fi
echo "APP 版本: $APPVER"

# 构建 staging
echo "构建安装包..."
STAGING_ROOT="staging"
STAGING_DIR="$STAGING_ROOT/$ARCH_MAP"
DEP_DIR="$STAGING_DIR/depends"
rm -rf "$STAGING_DIR"
mkdir -p "$DEP_DIR"

APP_BASE="$(basename "$APP_PKG")"
cp -f "$APP_PKG" "$STAGING_DIR/$APP_BASE"
# 固定文件名,install.sh 引用它
cp -f "$APP_PKG" "$STAGING_DIR/luci-app-passwall.${PKG_EXT}"

if [ -n "$I18N_PKG" ]; then
  I18N_BASE="$(basename "$I18N_PKG")"
  cp -f "$I18N_PKG" "$STAGING_DIR/$I18N_BASE"
  cp -f "$I18N_PKG" "$STAGING_DIR/luci-i18n-passwall-zh-cn.${PKG_EXT}"
fi

# 复制本地的 depends 目录(包含完整依赖)
echo "复制依赖包..."
if [ -d depends ]; then
  cp -r depends/* "$DEP_DIR/"
fi

# ------------------------------------------------------------------
# 生成安装脚本 (opkg/apk 双兼容)
# OpenWrt 24.10+/25 默认 apk,但仍可执行 opkg 命令(opkg 是 apk 的兼容 shim)
# ------------------------------------------------------------------
cat > "$STAGING_DIR/install.sh" <<EOF
#!/bin/sh
set -e

# 选择包管理器:apk 优先(opkg 在 24.10+/25 中是兼容 shim)
PKG_MGR="$PKG_MGR"
PKG_EXT="$PKG_EXT"

echo "========================================="
echo "PassWall 安装脚本"
echo "包管理器: \$PKG_MGR  包格式: .\$PKG_EXT"
echo "========================================="

# PassWall 必需依赖
check_passwall_deps() {
  echo "检查 PassWall 必需依赖..."

  local iptables_deps="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra"
  local kernel_deps="kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra"
  local other_deps="ip-full ipset iptables-mod-extra iptables-mod-filter"

  for dep in \$iptables_deps \$kernel_deps \$other_deps; do
    if ! \$PKG_MGR list-installed 2>/dev/null | grep -q "^\$dep "; then
      echo "安装缺失依赖: \$dep"
      \$PKG_MGR install "\$dep" 2>/dev/null || echo "警告: 无法安装 \$dep"
    fi
  done
}

# 刷新 LuCI 缓存(不重启)
refresh_luci() {
  rm -f /tmp/luci-indexcache 2>/dev/null || true
  rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
  if command -v luci-reload >/dev/null 2>&1; then
    luci-reload 2>/dev/null || true
  else
    if command -v lua >/dev/null 2>&1; then
      lua -e 'local ok,d=pcall(require,"luci.dispatcher"); if ok and d then if d.rebuild_index then d.rebuild_index() elseif d.createindex then d.createindex() end end' 2>/dev/null || true
    fi
    [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload 2>/dev/null || true
    [ -x /etc/init.d/nginx ]  && /etc/init.d/nginx  reload 2>/dev/null || true
  fi
  sync
}

APP_PKG="luci-app-passwall.\$PKG_EXT"
I18N_PKG="luci-i18n-passwall-zh-cn.\$PKG_EXT"

if [ ! -f "\$APP_PKG" ]; then
  echo "错误: 缺少 \$APP_PKG"
  ls -l
  exit 1
fi

refresh_luci

# 更新源(失败不中断)
\$PKG_MGR update 2>/dev/null || echo "警告: 更新源失败,继续..."

# 基础依赖
echo "安装基础依赖..."
\$PKG_MGR install luci-compat luci-lib-jsonc libuci-lua 2>/dev/null || true

check_passwall_deps

# 安装 depends 下的所有包(支持 .ipk 与 .apk)
if [ -d depends ]; then
  echo "安装依赖包..."
  for f in depends/*.\$PKG_EXT; do
    [ -f "\$f" ] || continue
    \$PKG_MGR install "\$f" 2>/dev/null || true
  done
fi

# 强制更新三大核心(xray/sing-box/hysteria)为随包附带版本
for core in xray sing-box hysteria; do
  core_pkg="\$(ls depends/\${core}_*.\$PKG_EXT 2>/dev/null | head -n1)"
  if [ -n "\$core_pkg" ]; then
    echo "更新核心 \$core -> \$core_pkg"
    \$PKG_MGR install "\$core_pkg" --force-reinstall --force-overwrite --force-architecture 2>/dev/null || true
  fi
done

echo "当前核心版本:"
/usr/bin/xray version 2>/dev/null | head -n1 || true
/usr/bin/sing-box version 2>/dev/null | head -n1 || true
/usr/bin/hysteria version 2>/dev/null | head -n2 || true

# 额外组件
echo "安装额外组件..."
\$PKG_MGR install haproxy shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server 2>/dev/null || true

# 强制重装 PassWall 主程序
echo "安装 PassWall 主程序..."
\$PKG_MGR install "\$APP_PKG" --force-reinstall || exit 1

# 语言包
if [ -f "\$I18N_PKG" ]; then
  echo "安装中文语言包: \$I18N_PKG"
  \$PKG_MGR install "\$I18N_PKG" 2>/dev/null || true
else
  echo "未发现本地中文语言包,跳过"
fi

if [ -x /etc/init.d/passwall ]; then
  /etc/init.d/passwall enable 2>/dev/null || true
  /etc/init.d/passwall start 2>/dev/null || true
fi

if [ -x /etc/init.d/firewall ]; then
  /etc/init.d/firewall reload 2>/dev/null || true
fi

refresh_luci

# 依赖校验
missing_deps=""
for dep in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange; do
  if ! \$PKG_MGR list-installed 2>/dev/null | grep -q "^\$dep "; then
    missing_deps="\$missing_deps \$dep"
  fi
done

if [ -n "\$missing_deps" ]; then
  echo "警告: 以下依赖未安装:\$missing_deps"
  echo "请手动执行: \$PKG_MGR install \$missing_deps"
fi

if [ -f /usr/lib/lua/luci/controller/passwall.lua ] || ls /usr/lib/lua/luci/controller/passwall/*.lua >/dev/null 2>&1; then
  echo "✓ 安装完成!请在 LuCI 界面 服务→PassWall 查看。"
  [ -z "\$missing_deps" ] && echo "  所有必需依赖已正确安装。"
  exit 0
else
  echo "! 警告: 未检测到 PassWall 控制器文件,可能需刷新浏览器。"
  exit 0
fi
EOF
chmod +x "$STAGING_DIR/install.sh"

OUTPUT="PassWall_${APPVER}_${ARCH_MAP}_all_sdk_${SDK_VERSION}.run"
LABEL="PassWall_${APPVER}_with_sdk_${SDK_VERSION}_${OPENSSL_TAG}_${PKG_EXT}"
makeself --gzip --nox11 "$STAGING_DIR" "$OUTPUT" "$LABEL" ./install.sh

echo "PassWall(luci-app)版本: $APPVER" > version.txt
echo "上游Release Tag: $APPVER-r1" >> version.txt
echo "SDK版本: $SDK_VERSION" >> version.txt
echo "OpenSSL标记: $OPENSSL_TAG" >> version.txt
echo "包格式: .$PKG_EXT (包管理器: $PKG_MGR)" >> version.txt
echo "构建时间: $BUILD_DATE" >> version.txt
echo "目标架构: $TARGET_ARCH" >> version.txt
echo "构建选项: $BUILD_OPTION" >> version.txt

rm -rf artifact/installer/*
mv -f "$OUTPUT" artifact/installer/
mv -f version.txt artifact/installer/

echo "========================================="
echo "构建成功!"
echo "构建产物:"
ls -lh artifact/installer/
echo "========================================="

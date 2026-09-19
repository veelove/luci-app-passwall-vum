#!/bin/bash
set -e

# 默认参数（同时兼容 OpenWrt 22.03 与 iStoreOS 25.x / OpenWrt 24.10+）
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

# 检查 passwall-ipk 目录是否为空，如果是则下载 IPK 包
if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
    echo "passwall-ipk 目录为空，正在下载 luci-app-passwall 和 luci-i18n-passwall-zh-cn 包..."

    # 通过 GitHub API 查询 release，拿到真实存在的 asset（兼容 apk / ipk）
    curl_gh() {
        if [ -n "$GITHUB_TOKEN" ]; then
            curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
        else
            curl -fsSL "$@"
        fi
    }

    RELEASE_JSON="$(curl_gh "https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest" || true)"
    if [ -z "$RELEASE_JSON" ] || [ "$RELEASE_JSON" = "null" ]; then
        echo "错误: 无法获取 Openwrt-Passwall/openwrt-passwall releases 信息"
        exit 1
    fi

    # 22.03 优先 ipk；其它（25.x / 24.10+）优先 apk
    case "$SDK_VERSION" in
        22.03*|19.07*|18.06*)
            APP_PATTERN="luci-app-passwall.*\\.ipk$"
            ;;
        *)
            APP_PATTERN="luci-app-passwall.*\\.apk$"
            ;;
    esac

    APP_URL="$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name | test(\"$APP_PATTERN\")) | .browser_download_url" | head -n1)"
    I18N_URL="$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | test("luci-i18n-passwall-zh-cn.*\\.ipk$")) | .browser_download_url' | head -n1)"

    # 兜底：找不到首选格式时尝试另一种格式
    if [ -z "$APP_URL" ] || [ "$APP_URL" = "null" ]; then
        case "$SDK_VERSION" in
            22.03*|19.07*|18.06*)
                APP_PATTERN="luci-app-passwall.*\\.apk$"
                ;;
            *)
                APP_PATTERN="luci-app-passwall.*\\.ipk$"
                ;;
        esac
        APP_URL="$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name | test(\"$APP_PATTERN\")) | .browser_download_url" | head -n1)"
    fi

    if [ -z "$APP_URL" ] || [ "$APP_URL" = "null" ]; then
        echo "错误: 在 release 中未找到 luci-app-passwall 包"
        echo "$RELEASE_JSON" | jq -r '.assets[] | .name'
        exit 1
    fi

    APP_FILENAME="$(basename "$APP_URL")"
    echo "尝试下载 APP: $APP_URL"
    if curl -fL "$APP_URL" -o "passwall-ipk/$APP_FILENAME"; then
        # apk 容器自身有 "ADB" 魔数；兼容 v2 ipk
        HEAD_BYTES="$(head -c 4 "passwall-ipk/$APP_FILENAME" | od -An -c | tr -d ' ')"
        if [ "$HEAD_BYTES" != "ADBd" ] && [ "$HEAD_BYTES" != "ADB!" ] && \
           ! file "passwall-ipk/$APP_FILENAME" | grep -q "gzip\|Debian\|ar archive"; then
            echo "错误: 下载的文件不是有效的 ipk/apk 包"
            rm -f "passwall-ipk/$APP_FILENAME"
            exit 1
        fi
        echo "成功下载 APP"
    else
        echo "错误: 无法下载 luci-app-passwall 包"
        exit 1
    fi

    if [ -n "$I18N_URL" ] && [ "$I18N_URL" != "null" ]; then
        I18N_FILENAME="$(basename "$I18N_URL")"
        echo "尝试下载 I18N: $I18N_URL"
        if curl -fL "$I18N_URL" -o "passwall-ipk/$I18N_FILENAME"; then
            echo "成功下载 I18N"
        else
            echo "警告: 无法下载中文语言包，将继续构建但不包含语言包"
        fi
    else
        echo "警告: 未找到中文语言包 asset，继续构建但不包含语言包"
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

# 定位 luci 包
echo "定位 luci 包..."
find_app() { find passwall-ipk -type f \( -name '*luci-app-passwall*.ipk' -o -name '*luci-app-passwall*.apk' \) 2>/dev/null | head -n1 || true; }
find_i18n() { find passwall-ipk -type f -name '*luci-i18n-passwall-zh-cn*.ipk' | head -n1 || true; }

APP_PKG="$(find_app)"
I18N_PKG="$(find_i18n)"

if [ -z "$APP_PKG" ]; then
  echo "错误: 未找到 luci-app-passwall 包"
  exit 1
fi

echo "定位到："
echo "APP: $APP_PKG"
echo "I18N: $I18N_PKG"

# 解析版本号
APP_PATH="$APP_PKG"
BASE="$(basename "$APP_PATH")"
APPVER="$(echo "$BASE" | sed -E 's/^.*luci-app-passwall_([^_]+).*\.ipk$/\1/')"
if [ -z "${APPVER:-}" ] || [ "$APPVER" = "$BASE" ]; then
  APPVER="25.11.15"
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
cp -f "$APP_PKG" "$STAGING_DIR/$APP_BASE"
# 同时复制一份固定文件名供 install.sh 探测（保留原扩展名 ipk/apk）
APP_STAGE_NAME="luci-app-passwall.${APP_BASE##*.}"
cp -f "$APP_PKG" "$STAGING_DIR/$APP_STAGE_NAME"

# 写入 SDK 版本标记，供 install.sh 在路由器上运行时识别
echo -n "$SDK_VERSION" > "$STAGING_DIR/.sdk_version"

if [ -n "$I18N_PKG" ]; then
  I18N_BASE="$(basename "$I18N_PKG")"
  cp -f "$I18N_PKG" "$STAGING_DIR/$I18N_BASE"
  cp -f "$I18N_PKG" "$STAGING_DIR/luci-i18n-passwall-zh-cn.ipk"
fi

# 复制本地的 depends 目录（包含完整依赖）
echo "复制依赖包..."
if [ -d depends ]; then
  cp -r depends/* "$DEP_DIR/"
fi

# 生成安装脚本（带引号 EOF 禁止 build.sh 阶段展开变量；运行时通过 .sdk_version 注入 SDK 版本）
cat > "$STAGING_DIR/install.sh" <<'INSTALL_EOF'
#!/bin/sh
set -e

# 由构建脚本写入的 SDK 版本标记，用于运行时选择依赖与刷新策略
SDK_VERSION="$(cat .sdk_version 2>/dev/null || echo @SDK_VERSION@)"

# 探测包管理器：iStoreOS 25 / ImmortalWrt 24.10+ 用 apk(Alpine)，OpenWrt 22.03/官方用 opkg
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
        # apk 仓库中不一定存在所有 OpenWrt 包（如 shadowsocks-libev-*）；
        # depends/ 目录已提供 shadowsocks-rust 等替代，因此静默失败即可
        apk add -q --force-overwrite --clean-protected --allow-untrusted "$dep" 2>/dev/null || true
    elif [ "$PKG_MGR" = "opkg" ]; then
        opkg install "$dep" 2>/dev/null || echo "警告: 无法安装 $dep"
    else
        echo "错误: 未找到包管理器，无法安装 $dep"
        return 1
    fi
}

# 手动解压 v1 ipk（gzip 压缩 control/data）到系统根目录 /，仅在 apk 环境用作依赖逃生通道
extract_ipk() {
    ipk_file="$1"
    [ -f "$ipk_file" ] || return 1
    work="$(mktemp -d)"
    # v1 ipk 是 gzip 压缩流（debian-binary + control.tar.gz + data.tar.gz）
    if ! gzip -dc "$ipk_file" 2>/dev/null | tar -xf - -C "$work" 2>/dev/null; then
        rm -rf "$work"
        echo "警告: $ipk_file 不是 gzip v1 ipk，解包失败"
        return 1
    fi
    # 解 data.tar.gz 到 /
    if [ -f "$work/data.tar.gz" ]; then
        tar -xzf "$work/data.tar.gz" -C / 2>/dev/null || true
        rm -rf "$work"
        echo "已解包: $ipk_file -> /"
        return 0
    fi
    rm -rf "$work"
    return 1
}

# 解 apk v2 容器（apk v2 = magic ADBd + 签名段 + control 段 + data 段）
# 优先用 apk extract（OpenWrt 25.12+/iStoreOS apk-tools 支持）；否则用 v1 ipk 解包兜底
extract_apk() {
    apk_file="$1"
    [ -f "$apk_file" ] || return 1
    # 1) apk extract --allow-untrusted --destination / file.apk（直接解到 /）
    #    iStoreOS 25 / OpenWrt 25.12+ 自带的 apk-tools 都支持此命令，且不触发依赖检查
    if command -v apk >/dev/null 2>&1; then
        if apk extract --allow-untrusted --destination / "$apk_file" 2>/dev/null; then
            echo "已解包(apk extract): $apk_file -> /"
            return 0
        fi
        # 探测输出：apk 不支持 extract 命令则回退
        if apk extract 2>&1 | grep -q "extract.*Extract package file contents" 2>/dev/null; then
            # 支持 extract 但 extract 失败（可能签名等其它原因），不要回退
            echo "警告: apk extract 失败，尝试 v1 ipk 解包"
        fi
    fi
    # 2) 兜底：用 tar/ar 直接尝试（v1 ipk 兼容路径）
    extract_ipk "$apk_file"
    return $?
}

# 从二进制 strings 提取嵌入版本号（用于 hysteria：apk 环境 version 子命令只输出 banner）
extract_binary_version() {
    bin="$1"
    [ -f "$bin" ] || return 1
    # 用 strings 提取 "X.Y.Z" 形式（排除 Go 依赖伪版本 0.0.0-2024...）
    strings -a "$bin" 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | grep -v "^0\.0\.0-" | head -n1
}

# 检查并安装 PassWall 必需依赖
check_passwall_deps() {
  echo "检查 PassWall 必需依赖..."

  # iptables 透明代理模块
  local iptables_deps="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra"
  local kernel_deps="kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra"

  for dep in $iptables_deps $kernel_deps; do
    if ! is_installed "$dep"; then
      echo "安装缺失依赖: $dep"
      install_dep "$dep" || true
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

    # iStoreOS 25 / OpenWrt 24.10+ 使用 ucode 重建索引
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

# 使用固定文件名，自动探测 ipk/apk
APP_PKG=""
for f in luci-app-passwall.ipk luci-app-passwall.apk; do
    if [ -f "$f" ]; then
        APP_PKG="$f"
        break
    fi
done
I18N_PKG="luci-i18n-passwall-zh-cn.ipk"

if [ -z "$APP_PKG" ]; then
  echo "错误: 缺少 luci-app-passwall.ipk / .apk"
  ls -l
  exit 1
fi

if [ -z "$PKG_MGR" ]; then
  echo "错误: 未找到包管理器 apk/opkg，请确认路由器系统（需要 OpenWrt/iStoreOS 类系统）"
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
        install_dep luci-compat 2>/dev/null || true
        install_dep luci-lib-jsonc 2>/dev/null || true
        install_dep libuci-lua 2>/dev/null || true
        ;;
    *)
        install_dep luci-lib-jsonc 2>/dev/null || true
        install_dep libuci-lua 2>/dev/null || true
        install_dep ucode 2>/dev/null || true
        install_dep ucode-mod-lua 2>/dev/null || true
        ;;
esac

# 检查并安装 PassWall 必需依赖
check_passwall_deps

# 安装 depends 下的 ipk
# opkg 环境直接 opkg install；apk 环境因 apk 仓库没有 PassWall 专用工具，改用手工解包到 /
if [ -d depends ] && ls depends/*.ipk >/dev/null 2>&1; then
  if [ "$PKG_MGR" = "opkg" ]; then
    echo "安装依赖包..."
    opkg install depends/*.ipk || true
  else
    echo "apk 环境手工解包依赖包到 /..."
    for ipk in depends/*.ipk; do
      extract_ipk "$ipk" || true
    done
  fi
fi

# 强制更新三大核心为随包附带的最新版本（覆盖路由器上已安装的旧版本）
for core in xray sing-box hysteria; do
    core_pkg="$(ls depends/${core}_*.ipk 2>/dev/null | head -n1)"
    if [ -n "$core_pkg" ]; then
      echo "更新核心 $core -> $core_pkg"
      if [ "$PKG_MGR" = "apk" ]; then
        extract_ipk "$core_pkg" || true
      else
        opkg install "$core_pkg" --force-reinstall --force-overwrite --force-architecture 2>/dev/null || true
      fi
    fi
done

# apk 环境：hysteria version 命令只输出 ASCII art banner，需要写 wrapper 让版本号先输出
# PassWall LuCI 控制器也用 hysteria version 读版本
if [ "$PKG_MGR" = "apk" ] && [ -x /usr/bin/hysteria ]; then
    HY_VER="$(extract_binary_version /usr/bin/hysteria 2>/dev/null)"
    if [ -n "$HY_VER" ]; then
        mv /usr/bin/hysteria /usr/bin/hysteria.bin
        cat > /usr/bin/hysteria <<HYST
#!/bin/sh
# hysteria wrapper: version subcommand 在 apk 环境下原本只输出 banner
# 这里在 banner 前先输出一行真实版本号，方便 PassWall LuCI 解析
if [ "\$1" = "version" ]; then
    echo "Version $HY_VER"
fi
exec /usr/bin/hysteria.bin "\$@"
HYST
        chmod +x /usr/bin/hysteria
        echo "✓ hysteria wrapper 已安装（version 输出 Version $HY_VER）"
    fi
fi

# 打印核心版本，便于确认
echo "当前核心版本："
/usr/bin/xray version 2>/dev/null | head -n1 || true
/usr/bin/sing-box version 2>/dev/null | head -n1 || true
# hysteria: 优先用嵌入版本字符串，回退到 'version' 命令
hy_ver="$(extract_binary_version /usr/bin/hysteria 2>/dev/null)"
if [ -n "$hy_ver" ]; then
    echo "Hysteria $hy_ver"
else
    /usr/bin/hysteria version 2>/dev/null | tail -n1 || true
fi

# 额外常用组件（容错）
echo "安装额外组件..."
install_dep haproxy 2>/dev/null || true
install_dep shadowsocks-libev-ss-local 2>/dev/null || true
install_dep shadowsocks-libev-ss-redir 2>/dev/null || true
install_dep shadowsocks-libev-ss-server 2>/dev/null || true

# 始终强制重装，避免版本判断带来的不确定性
echo "安装 PassWall 主程序..."
if [ "$PKG_MGR" = "apk" ]; then
    # apk 环境：依赖已通过手工解包 depends/ 注入到 /；用 apk extract 绕过 apk 依赖解析
    extract_apk "$APP_PKG" || exit 1
else
    opkg install "$APP_PKG" --force-reinstall || exit 1
fi

# 安装中文语言包（仅本地文件）
if [ -f "$I18N_PKG" ]; then
  echo "安装中文语言包: $I18N_PKG"
  if [ "$PKG_MGR" = "apk" ]; then
    # apk 环境手工解包 i18n，避免依赖解析
    extract_apk "$I18N_PKG" || true
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

# 验证依赖安装情况
echo "验证关键依赖..."
missing_deps=""
for dep in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange; do
  if ! is_installed "$dep"; then
    missing_deps="$missing_deps $dep"
  fi
done

if [ -n "$missing_deps" ]; then
  echo "警告: 以下依赖未安装，可能影响透明代理功能:$missing_deps"
  if [ "$PKG_MGR" = "apk" ]; then
    echo "请手动执行: apk add$missing_deps"
  else
    echo "请手动执行: opkg install$missing_deps"
  fi
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
  echo "! 警告: 未检测到 PassWall 控制器文件，可能需刷新浏览器或重新登录 LuCI。"
  exit 0
fi
INSTALL_EOF
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

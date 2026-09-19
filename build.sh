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
# 根据 SDK_VERSION 判断期望的包格式:
#   23.x 及更早 -> .ipk / opkg
#   24.10+ / 25 -> .apk / apk(opkg 兼容)
# 后面如果 API 探测到的资产格式不一致,会基于实际下载再覆盖 PKG_EXT。
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
echo "构建期默认包格式: .$PKG_EXT  (包管理器: $PKG_MGR)"

# 准备环境
echo "准备环境..."
rm -rf artifact/installer staging cores
mkdir -p passwall-ipk artifact/installer staging cores

# 解析版本主号: 25.00.0 -> 25.00.0  / 24.10.6 -> 24.10.6  / 23.05.5 -> 23.05.5
SDK_MAJOR="$(echo "$SDK_VERSION" | cut -d. -f1)"

# 检查 passwall-ipk 目录是否为空，如果是则下载 luci-app-passwall 主包
if [ -z "$(ls -A passwall-ipk/ 2>/dev/null)" ]; then
    echo "passwall-ipk 目录为空,正在通过 GitHub API 探测上游 release asset..."

    # 已知最近版本(可在 workflow 中覆盖)
    RELEASE_TAG="${RELEASE_TAG:-26.5.11-1}"
    REPO="Openwrt-Passwall/openwrt-passwall"

    # 通过 GitHub API 列出 release 资产,根据 SDK_VERSION + 扩展名选最匹配的 apk/ipk
    # 优先级(SDK 25.x): 25.x 命名的 apk > 25.12+ 命名的 apk > 其他 apk > ipk
    # 优先级(SDK 24.10.x): 24.10 命名的 apk > 23.05-24.10 命名的 ipk > 任意 ipk
    # 优先级(SDK 23.x): 23.05 命名的 ipk > 任意 ipk
    if command -v jq >/dev/null 2>&1; then
        if [ -n "$GITHUB_TOKEN" ]; then
            API_JSON="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}" 2>/dev/null || true)"
        else
            API_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}" 2>/dev/null || true)"
        fi
        [ -z "$API_JSON" ] && API_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"

        if [ -n "$API_JSON" ]; then
            # APP 包 URL:luci-app-passwall 主程序
            # 关键:SDK 25.x 强制只选 .apk(因为 ipk 在 apk 环境下无法正确解析)
            if [ "$SDK_MAJOR" = "25" ]; then
                # 优先 25.12+ 命名的真 apk
                APP_URL="$(echo "$API_JSON" | jq -r '
                  ( .assets[] | select(
                      ( .name | test("^25\\.12\\+") )
                      and ( .name | test("luci-app-passwall") )
                      and ( .name | test("\\.apk$") )
                    ) | .browser_download_url ) // empty
                ' 2>/dev/null | head -n1)"
                # 次选任何 .apk(用于更新 SDK 数字如 25.05、25.13 时)
                if [ -z "$APP_URL" ]; then
                    APP_URL="$(echo "$API_JSON" | jq -r '
                      ( .assets[] | select(
                          ( .name | test("luci-app-passwall") )
                          and ( .name | test("\\.apk$") )
                        ) | .browser_download_url ) // empty
                    ' 2>/dev/null | head -n1)"
                fi
            else
                # 23.x / 24.x 优先选 ipk(因为上游没有 24 的 apk,只有 23.05-24.10 的 ipk)
                APP_URL="$(echo "$API_JSON" | jq -r '
                  ( .assets[] | select(
                      ( .name | test("luci-app-passwall") )
                      and ( .name | test("\\.ipk$") )
                    ) | .browser_download_url ) // empty
                ' 2>/dev/null | head -n1)"
                # 兜底:任何 luci-app-passwall 包
                if [ -z "$APP_URL" ]; then
                    APP_URL="$(echo "$API_JSON" | jq -r '
                      ( .assets[] | select(.name | test("luci-app-passwall")) | .browser_download_url) // empty
                    ' 2>/dev/null | head -n1)"
                fi
            fi

            # I18N URL:同样的策略
            if [ "$SDK_MAJOR" = "25" ]; then
                I18N_URL="$(echo "$API_JSON" | jq -r '
                  ( .assets[] | select(
                      ( .name | test("^25\\.12\\+") )
                      and ( .name | test("luci-i18n-passwall-zh-cn") )
                      and ( .name | test("\\.apk$") )
                    ) | .browser_download_url ) // empty
                ' 2>/dev/null | head -n1)"
                if [ -z "$I18N_URL" ]; then
                    I18N_URL="$(echo "$API_JSON" | jq -r '
                      ( .assets[] | select(
                          ( .name | test("luci-i18n-passwall-zh-cn") )
                          and ( .name | test("\\.apk$") )
                        ) | .browser_download_url ) // empty
                    ' 2>/dev/null | head -n1)"
                fi
            else
                I18N_URL="$(echo "$API_JSON" | jq -r '
                  ( .assets[] | select(
                      ( .name | test("luci-i18n-passwall-zh-cn") )
                      and ( .name | test("\\.ipk$") )
                    ) | .browser_download_url ) // empty
                ' 2>/dev/null | head -n1)"
                if [ -z "$I18N_URL" ]; then
                    I18N_URL="$(echo "$API_JSON" | jq -r '
                        ( .assets[] | select(.name | test("luci-i18n-passwall-zh-cn")) | .browser_download_url) // empty
                    ' 2>/dev/null | head -n1)"
                fi
            fi
        fi
    fi

    # 兜底:没有 jq 或 API 失败时,硬编码已知的 26.5.11-1 命名
    if [ -z "$APP_URL" ]; then
        echo "警告: GitHub API 探测失败,使用硬编码 URL 兜底"
        case "$SDK_VERSION" in
            25.*)
                # 25.x 强制只指向真 apk 文件(ADBd 魔数)
                APP_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/25.12%2B_luci-app-passwall-26.5.11-r1.apk"
                I18N_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/25.12%2B_luci-i18n-passwall-zh-cn-26.5.11.apk"
                ;;
            23.*)
                APP_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/23.05-24.10_luci-app-passwall_26.5.11-r1_all.ipk"
                I18N_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/23.05-24.10_luci-i18n-passwall-zh-cn_26.5.11_all.ipk"
                ;;
            *)
                APP_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/22.03-_luci-app-passwall_26.5.11_all.ipk"
                I18N_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/22.03-_luci-i18n-passwall-zh-cn_26.5.11_all.ipk"
                ;;
        esac
    fi

    echo "APP URL: $APP_URL"
    if ! curl -fL "$APP_URL" -o "passwall-ipk/$(basename "${APP_URL//%2B/+}")"; then
        echo "错误: 无法下载 luci-app-passwall 包: $APP_URL"
        exit 1
    fi
    echo "成功下载 APP"

    if [ -n "$I18N_URL" ]; then
        echo "I18N URL: $I18N_URL"
        if curl -fL "$I18N_URL" -o "passwall-ipk/$(basename "${I18N_URL//%2B/+}$")"; then
            echo "成功下载 I18N"
        else
            echo "警告: 无法下载中文语言包,将继续构建但不包含语言包"
        fi
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

# ------------------------------------------------------------------
# 根据实际拿到的 luci-app-passwall 包扩展名,覆盖 PKG_EXT/PKG_MGR
# (上游 release 资产命名不完全按 SDK 区分,可能 24.10 SDK 拿到 ipk、也可能 25 SDK 拿到 apk)
# install.sh 会在路由器上运行时探测,但构建期 staging 内的固定文件名要一致。
# ------------------------------------------------------------------
APP_EXT_ACTUAL="$(ls passwall-ipk/*luci-app-passwall*.ipk passwall-ipk/*luci-app-passwall*.apk 2>/dev/null | head -n1)"
APP_EXT_ACTUAL="${APP_EXT_ACTUAL##*.}"
if [ -n "$APP_EXT_ACTUAL" ]; then
    if [ "$APP_EXT_ACTUAL" != "$PKG_EXT" ]; then
        echo "调整:实际下载格式 .$APP_EXT_ACTUAL 覆盖默认 .$PKG_EXT"
        PKG_EXT="$APP_EXT_ACTUAL"
        case "$PKG_EXT" in
            ipk) PKG_MGR="opkg" ;;
            apk) PKG_MGR="apk" ;;
        esac
    fi
fi
echo "最终包格式: .$PKG_EXT  (包管理器: $PKG_MGR)"

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
# 固定文件名,install.sh 探测时按可用扩展名选对应那个
cp -f "$APP_PKG" "$STAGING_DIR/luci-app-passwall.${PKG_EXT}"

if [ -n "$I18N_PKG" ]; then
  I18N_BASE="$(basename "$I18N_PKG")"
  cp -f "$I18N_PKG" "$STAGING_DIR/$I18N_BASE"
  cp -f "$I18N_PKG" "$STAGING_DIR/luci-i18n-passwall-zh-cn.${PKG_EXT}"
fi

# 写入 SDK 版本标记,install.sh 运行时读取以决定依赖集合与刷新策略
echo -n "$SDK_VERSION" > "$STAGING_DIR/.sdk_version"

# 复制本地的 depends 目录(包含完整依赖)
echo "复制依赖包..."
if [ -d depends ]; then
  cp -r depends/* "$DEP_DIR/"

  # apk 环境需要 .apk 副本(从 ipk 结构中提取 control.tar.gz + data.tar.gz,重新打包)
  # 局部禁用 set -e,避免子 shell 退出码导致整个循环被中断
  set +e
  for src in "$DEP_DIR"/*.ipk; do
    [ -f "$src" ] || continue
    base="$(basename "$src" .ipk)"
    dst="$DEP_DIR/${base}.apk"
    [ -f "$dst" ] && continue
    WORK="$(mktemp -d)"
    tar -xzf "$src" -C "$WORK" 2>/dev/null

    # 情况 A:展开后是 control/ + data/ 目录(罕见)
    if [ -d "$WORK/control" ] && [ -d "$WORK/data" ]; then
      tar -czf "$WORK/control.tar.gz" -C "$WORK/control" .
      tar -czf "$WORK/data.tar.gz"    -C "$WORK/data"    .
    # 情况 B:展开后直接是 control.tar.gz + data.tar.gz(常见)
    elif [ -f "$WORK/control.tar.gz" ] && [ -f "$WORK/data.tar.gz" ]; then
      :  # 已经在 WORK 根目录,无需再处理
    else
      echo "  跳过(无法识别结构): $(basename "$src")"
      rm -rf "$WORK"
      continue
    fi

    # 最终 APK = control.tar.gz + data.tar.gz (无签名,依赖 --allow-untrusted)
    tar -czf "$dst" -C "$WORK" control.tar.gz data.tar.gz
    echo "  转换依赖: $(basename "$src") -> $(basename "$dst")"
    rm -rf "$WORK"
  done
  set -e
fi

# ------------------------------------------------------------------
# 注意:参考 openclash 项目的做法,apk 环境(OpenWrt 24.10+/25)下不安装
# depends/*.ipk(apk 命令无法读取 ipk 格式)。depends 仅作为 opkg 环境
# (OpenWrt 23.x) 的兜底,运行时由 install.sh 按 PKG_MGR 决定是否安装。
# 因此这里不需要做 ipk -> apk 的重打包。
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 生成安装脚本 (opkg/apk 双兼容)
# OpenWrt 24.10+/25 默认 apk,但仍可执行 opkg 命令(opkg 是 apk 的兼容 shim)
# ------------------------------------------------------------------
cat > "$STAGING_DIR/install.sh" <<'INSTALL_EOF'
#!/bin/sh
set -e

# 由构建脚本写入的 SDK 版本标记，用于运行时选择依赖与刷新策略
SDK_VERSION="$(cat .sdk_version 2>/dev/null || echo @SDK_VERSION@)"

# 探测包管理器：iStoreOS 25 / OpenWrt 24.10+ 用 apk(Alpine)；
# OpenWrt 23.x / 22.03 官方用 opkg。
PKG_MGR=""
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
fi
echo "检测到包管理器: ${PKG_MGR:-未找到}"

# 检查依赖是否已安装（按包管理器分支）
is_installed() {
    dep="$1"
    if [ "$PKG_MGR" = "apk" ]; then
        apk info -e "$dep" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -q "^$dep "
    fi
}

# 安装依赖（按包管理器分支）
install_dep() {
    dep="$1"
    if [ "$PKG_MGR" = "apk" ]; then
        apk add -q --force-overwrite --clean-protected --allow-untrusted "$dep" 2>/dev/null \
            || echo "警告: 无法安装 $dep"
    elif [ "$PKG_MGR" = "opkg" ]; then
        opkg install "$dep" 2>/dev/null \
            || echo "警告: 无法安装 $dep"
    else
        echo "错误: 未找到包管理器，无法安装 $dep"
        return 1
    fi
}

# PassWall 必需依赖
check_passwall_deps() {
    echo "检查 PassWall 必需依赖..."

    # 按 SDK 版本挑选基础依赖集合
    local base_deps=""
    case "$SDK_VERSION" in
        22.03*|19.07*|18.06*|23.05*)
            # 旧版：需要 luci-compat，无 ucode
            base_deps="luci-compat luci-lib-jsonc libuci-lua coreutils-nohup bash iptables dnsmasq-full curl ca-certificates ipset ip-full iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-extra iptables-mod-filter iptables-mod-conntrack-extra kmod-tun kmod-inet-diag unzip"
            ;;
        *)
            # OpenWrt 24.10+/25：ucode 替代 lua，无 luci-compat
            base_deps="luci-lib-jsonc libuci-lua ucode ucode-mod-lua coreutils-nohup bash iptables dnsmasq-full curl ca-certificates ipset ip-full iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-extra iptables-mod-filter iptables-mod-conntrack-extra kmod-tun kmod-inet-diag unzip"
            ;;
    esac

    local kernel_deps="kmod-ipt-tproxy kmod-ipt-socket kmod-ipt-iprange kmod-ipt-conntrack-extra"

    for dep in $base_deps $kernel_deps; do
        if ! is_installed "$dep"; then
            echo "安装缺失依赖: $dep"
            install_dep "$dep" || true
        fi
    done
}

# 刷新 LuCI 缓存（不重启）
refresh_luci() {
    rm -f /tmp/luci-indexcache 2>/dev/null || true
    rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
    if command -v luci-reload >/dev/null 2>&1; then
        luci-reload 2>/dev/null || true
    else
        if command -v lua >/dev/null 2>&1; then
            lua -e 'local ok,d=pcall(require,"luci.dispatcher"); if ok and d then if d.rebuild_index then d.rebuild_index() elseif d.createindex then d.createindex() end end' 2>/dev/null || true
        fi
        if command -v ucode >/dev/null 2>&1; then
            ucode -e 'require("luci.dispatcher").rebuild_index?.()' 2>/dev/null || true
        fi
        if [ -x /etc/init.d/uhttpd ]; then
            /etc/init.d/uhttpd reload 2>/dev/null || true
        fi
        if [ -x /etc/init.d/nginx ]; then
            /etc/init.d/nginx reload 2>/dev/null || true
        fi
        if [ -x /etc/init.d/rpcd ]; then
            /etc/init.d/rpcd reload 2>/dev/null || true
        fi
    fi
    sync
}

# 主包探测：构建期会把 ipk/apk 都放到 staging(固定名),脚本按可用管理器选对应那个
APP_PKG=""
for f in luci-app-passwall.ipk luci-app-passwall.apk; do
    if [ -f "$f" ]; then
        APP_PKG="$f"
        break
    fi
done
I18N_PKG=""
for f in luci-i18n-passwall-zh-cn.ipk luci-i18n-passwall-zh-cn.apk; do
    if [ -f "$f" ]; then
        I18N_PKG="$f"
        break
    fi
done

if [ -z "$APP_PKG" ]; then
    echo "错误: 缺少 luci-app-passwall.ipk / .apk"
    ls -l
    exit 1
fi

if [ -z "$PKG_MGR" ]; then
    echo "错误: 未找到包管理器 apk/opkg，请确认路由器系统（需要 OpenWrt/iStoreOS 类系统）"
    exit 1
fi

echo "========================================="
echo "PassWall 安装脚本"
echo "SDK 版本: $SDK_VERSION"
echo "包管理器: $PKG_MGR"
echo "主包:     $APP_PKG"
echo "语言包:   ${I18N_PKG:-无}"
echo "========================================="

refresh_luci

# 更新软件源
if [ "$PKG_MGR" = "apk" ]; then
    apk update || { echo "apk update 失败，请检查路由器网络以及软件源。"; exit 1; }
else
    opkg update || { echo "更新软件源列表错误，请检查路由器网络以及软件源。"; exit 1; }
fi

# 基础依赖（按 SDK 分支）
echo "安装基础依赖..."
case "$SDK_VERSION" in
    22.03*|19.07*|18.06*|23.05*)
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

check_passwall_deps

# 安装 depends 下的依赖
# opkg 环境:装 ipk;apk 环境:装 apk(由 build.sh 在 staging 阶段自动从 ipk 转好的副本)
if [ -d depends ]; then
    if [ "$PKG_MGR" = "opkg" ] && ls depends/*.ipk >/dev/null 2>&1; then
        echo "安装依赖包 (opkg)..."
        opkg install depends/*.ipk || true
    elif [ "$PKG_MGR" = "apk" ] && ls depends/*.apk >/dev/null 2>&1; then
        echo "安装依赖包 (apk)..."
        for f in depends/*.apk; do
            apk add -q --force-overwrite --clean-protected --allow-untrusted "$f" 2>/dev/null || true
        done
    fi
fi

# 强制更新三大核心（xray/sing-box/hysteria）为随包附带版本
for core in xray sing-box hysteria; do
    if [ "$PKG_MGR" = "opkg" ]; then
        core_pkg="$(ls depends/${core}_*.ipk 2>/dev/null | head -n1)"
        if [ -n "$core_pkg" ]; then
            echo "更新核心 $core -> $core_pkg"
            opkg install "$core_pkg" --force-reinstall --force-overwrite --force-architecture 2>/dev/null || true
        fi
    else
        core_pkg="$(ls depends/${core}_*.apk 2>/dev/null | head -n1)"
        if [ -n "$core_pkg" ]; then
            echo "更新核心 $core -> $core_pkg"
            apk add -q --force-overwrite --clean-protected --allow-untrusted "$core_pkg" 2>/dev/null || true
        fi
    fi
done

echo "当前核心版本:"
/usr/bin/xray version 2>/dev/null | head -n1 || true
/usr/bin/sing-box version 2>/dev/null | head -n1 || true
/usr/bin/hysteria version 2>/dev/null | head -n2 || true

# 额外常用组件（apk/opkg 各自兜底）
echo "安装额外组件..."
for pkg in haproxy shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server; do
    if ! is_installed "$pkg"; then
        install_dep "$pkg" || true
    fi
done

# 安装 PassWall 主程序
echo "安装 PassWall 主程序..."
if [ "$PKG_MGR" = "apk" ]; then
    apk add -q --force-overwrite --clean-protected --allow-untrusted "$APP_PKG" || exit 1
else
    opkg install "$APP_PKG" --force-reinstall || exit 1
fi

# 安装中文语言包（仅本地文件）
if [ -n "$I18N_PKG" ]; then
    echo "安装中文语言包: $I18N_PKG"
    if [ "$PKG_MGR" = "apk" ]; then
        apk add -q --force-overwrite --clean-protected --allow-untrusted "$I18N_PKG" 2>/dev/null || true
    else
        opkg install "$I18N_PKG" 2>/dev/null || true
    fi
else
    echo "未发现本地中文语言包，跳过"
fi

# 启用并启动服务
if [ -x /etc/init.d/passwall ]; then
    echo "启用 PassWall 服务..."
    /etc/init.d/passwall enable 2>/dev/null || true
    /etc/init.d/passwall start 2>/dev/null || true
fi

if [ -x /etc/init.d/firewall ]; then
    echo "重载防火墙规则..."
    /etc/init.d/firewall reload 2>/dev/null || true
fi

refresh_luci

# 依赖校验
missing_deps=""
for dep in iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange; do
    if ! is_installed "$dep"; then
        missing_deps="$missing_deps $dep"
    fi
done

if [ -n "$missing_deps" ]; then
    echo "警告: 以下依赖未安装:$missing_deps"
    echo "请手动执行: $PKG_MGR install $missing_deps"
fi

if [ -f /usr/lib/lua/luci/controller/passwall.lua ] || ls /usr/lib/lua/luci/controller/passwall/*.lua >/dev/null 2>&1; then
    echo "✓ 安装完成！请在 LuCI 界面 服务→PassWall 查看。"
    echo "  如果菜单未显示，请刷新浏览器或重新登录 LuCI。"
    [ -z "$missing_deps" ] && echo "  所有必需依赖已正确安装。"
    exit 0
else
    echo "! 警告: 未检测到 PassWall 控制器文件，可能需刷新浏览器或重新登录 LuCI。"
    exit 0
fi
INSTALL_EOF
chmod +x "$STAGING_DIR/install.sh"

# 把占位符 @SDK_VERSION@ 替换为构建时的 SDK 版本(兼容 macOS BSD sed)
if sed --version >/dev/null 2>&1; then
    sed -i "s|@SDK_VERSION@|$SDK_VERSION|g" "$STAGING_DIR/install.sh"
else
    sed -i '' "s|@SDK_VERSION@|$SDK_VERSION|g" "$STAGING_DIR/install.sh"
fi

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

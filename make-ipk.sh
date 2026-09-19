#!/bin/bash
#
# Usage:
#   ./make-ipk.sh xray [output_dir]        [pkg_ext]
#   ./make-ipk.sh hysteria [output_dir]    [pkg_ext]
#   ./make-ipk.sh geoview [output_dir]     [pkg_ext]
#   ./make-ipk.sh sing-box [output_dir]    [pkg_ext]
#   ./make-ipk.sh all [output_dir]         [pkg_ext]
#
# 自动从 GitHub 下载最新静态编译二进制，打包成 OpenWrt 包。
# pkg_ext 默认 apk(OpenWrt 24.10+/25.x),可指定 ipk(23.x 及更早)。
#
# 同时兼容 OpenWrt 23.x (ipk) 与 24.10+/25.x (apk) 两种包格式。
#

set -e

PKG="$1"
OUT="${2:-.}"
PKG_EXT="${3:-apk}"  # 默认生成 .apk;旧 OpenWrt 23.x 请显式传 ipk

if [ -z "$PKG" ]; then
  echo "Usage: $0 <package> [output_dir] [pkg_ext]"
  echo "Packages: xray, hysteria, geoview, sing-box, all"
  echo "pkg_ext: apk (default, OpenWrt 24.10+/25.x) | ipk (OpenWrt 23.x 及更早)"
  exit 1
fi

if [ "$PKG_EXT" != "ipk" ] && [ "$PKG_EXT" != "apk" ]; then
  echo "ERROR: pkg_ext must be 'ipk' or 'apk', got: $PKG_EXT"
  exit 1
fi

if [ ! -d "$OUT" ]; then
  echo "ERROR: output dir not found: $OUT"
  exit 1
fi

# 根据 pkg_ext 决定 control 文件格式
# OpenWrt 24.10+/25 apk 包使用与 ipk 相同的 control 字段,但包头签名不同。
# 这里我们采用 ipk 风格的 control + 包扩展名的"伪 apk"输出(在仓库内仍然有效,
# 因为 OpenWrt apk 工具链兼容 ipk 结构)。如需严格的 APK tar.gz 结构,可
# 后续切换为 mksquashfs + openssl 签名。
build_package() {
  local PKG_NAME="$1"
  local OUT_DIR="$2"

  local WORK=$(mktemp -d)
  mkdir -p "$WORK/control" "$WORK/data/usr/bin"

  local VER=""
  local FILE=""

  case "$PKG_NAME" in
    xray)
      VER=$(curl -sL "https://github.com/XTLS/Xray-core/releases" | grep -o '/releases/tag/v[^"]*' | head -1 | sed 's|/releases/tag/v||')
      echo "=== xray @ v$VER ==="
      curl -sL "https://github.com/XTLS/Xray-core/releases/download/v$VER/Xray-linux-64.zip" -o "$WORK/xray.zip"
      unzip -o "$WORK/xray.zip" xray -d "$WORK"
      chmod +x "$WORK/xray"
      FILE="$WORK/xray"
      ;;

    hysteria)
      TAG=$(curl -sL "https://github.com/apernet/hysteria/releases" | grep -o '/releases/tag/[^"]*' | head -1 | sed 's|/releases/tag/||')
      VER=$(echo "$TAG" | sed 's|app%2Fv||' | tr '%/' '-')
      echo "=== hysteria @ $VER ==="
      URL="https://github.com/apernet/hysteria/releases/download/$TAG/hysteria-linux-amd64-avx"
      if ! curl -sIL "$URL" | grep -q "^HTTP.*200"; then
        URL="https://github.com/apernet/hysteria/releases/download/$TAG/hysteria-linux-amd64"
      fi
      curl -sL "$URL" -o "$WORK/hysteria"
      chmod +x "$WORK/hysteria"
      FILE="$WORK/hysteria"
      ;;

    geoview)
      VER=$(curl -sL "https://github.com/snowie2000/geoview/releases" | grep -o 'releases/tag/[^"]*' | head -1 | sed 's|releases/tag/||')
      if [ -z "$VER" ]; then
        VER="0.2.6"
      fi
      echo "=== geoview @ $VER ==="
      curl -sL "https://github.com/snowie2000/geoview/releases/download/$VER/geoview-linux-amd64" -o "$WORK/geoview"
      chmod +x "$WORK/geoview"
      FILE="$WORK/geoview"
      ;;

    sing-box)
      TAG=$(curl -sL "https://github.com/SagerNet/sing-box/releases" | grep -o '/releases/tag/v[^"]*' | head -1 | sed 's|/releases/tag/v||')
      VER="$TAG"
      echo "=== sing-box @ $VER ==="
      curl -sL "https://github.com/SagerNet/sing-box/releases/download/v$TAG/sing-box-$TAG-linux-amd64.tar.gz" -o "$WORK/sing-box.tar.gz"
      tar -xzf "$WORK/sing-box.tar.gz" -C "$WORK"
      SUBDIR=$(ls -d "$WORK"/sing-box-* 2>/dev/null | head -1)
      if [ -z "$SUBDIR" ]; then
        echo "ERROR: sing-box extraction failed"
        return 1
      fi
      cp "$SUBDIR/sing-box" "$WORK/sing-box"
      chmod +x "$WORK/sing-box"
      FILE="$WORK/sing-box"
      ;;
  esac

  if [ -z "$FILE" ]; then
    echo "ERROR: failed to get binary for $PKG_NAME"
    rm -rf "$WORK"
    return 1
  fi

  echo "Binary: $FILE"

  # 探测架构
  RAW=$(file "$FILE")
  if echo "$RAW" | grep -q 'aarch64\|arm64'; then
    ARCH="aarch64"
  elif echo "$RAW" | grep -q 'armv7'; then
    ARCH="arm_armv7"
  elif echo "$RAW" | grep -q 'armv6'; then
    ARCH="arm_armv6"
  elif echo "$RAW" | grep -q 'x86-64\|x86_64\|amd64'; then
    ARCH="x86_64"
  elif echo "$RAW" | grep -q 'mips64le\|mips64'; then
    ARCH="mips64el"
  elif echo "$RAW" | grep -q 'mipsle\|mips'; then
    ARCH="mipsel"
  else
    echo "WARNING: unknown arch from 'file', using x86_64"
    ARCH="x86_64"
  fi
  echo "Arch: $ARCH"

  cp "$FILE" "$WORK/data/usr/bin/$PKG_NAME"

  cat > "$WORK/control/control" << EOF
Package: $PKG_NAME
Version: $VER
Architecture: $ARCH
Maintainer: vee
Description: $PKG_NAME binary package
EOF

  if [ "$PKG_EXT" = "apk" ]; then
    # OpenWrt 24.10+/25.x 的 .apk 包格式 = tar.gz 包含三个文件
    # (与 ipk 相同的 control.tar.gz / data.tar.gz + .SIGN.RSA.* 签名,
    #  无签名时仍可被 apk 工具链识别)
    tar -C "$WORK/control" -czf "$WORK/control.tar.gz" .
    tar -C "$WORK/data"    -czf "$WORK/data.tar.gz" .
    IPK="$OUT_DIR/${PKG_NAME}_${VER}_${ARCH}.apk"
    tar -C "$WORK" -czf "$IPK" control.tar.gz data.tar.gz
  else
    # 传统 ipk 格式(debian-binary + control.tar.gz + data.tar.gz)
    tar -C "$WORK/control" -czf "$WORK/control.tar.gz" .
    tar -C "$WORK/data"    -czf "$WORK/data.tar.gz" .
    printf '2.0\n' > "$WORK/debian-binary"
    IPK="$OUT_DIR/${PKG_NAME}_${VER}_${ARCH}.ipk"
    tar -C "$WORK" -czf "$IPK" debian-binary control.tar.gz data.tar.gz
  fi

  echo ""
  echo "Done: $IPK"
  echo "Size: $(du -sh "$IPK" | cut -f1)"
  echo "----------------------------------------"

  rm -rf "$WORK"
  return 0
}

if [ "$PKG" = "all" ]; then
  echo "========================================"
  echo "开始全面打包所有包 (.$PKG_EXT)..."
  echo "========================================"
  echo ""

  for pkg in xray hysteria geoview sing-box; do
    echo ""
    echo "========================================"
    echo "正在打包: $pkg"
    echo "========================================"
    build_package "$pkg" "$OUT" || echo "警告: 打包 $pkg 失败"
  done

  echo ""
  echo "========================================"
  echo "全面打包完成!"
  echo "========================================"
  exit 0
fi

case "$PKG" in
  xray|hysteria|geoview|sing-box)
    build_package "$PKG" "$OUT"
    ;;
  *)
    echo "ERROR: unknown package '$PKG'"
    echo "Available: xray, hysteria, geoview, sing-box, all"
    exit 1
    ;;
esac

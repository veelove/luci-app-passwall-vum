#!/bin/bash
#
# Usage:
#   ./make-ipk.sh xray [output_dir]
#   ./make-ipk.sh hysteria [output_dir]
#   ./make-ipk.sh geoview [output_dir]
#   ./make-ipk.sh sing-box [output_dir]
#   ./make-ipk.sh all [output_dir]
#
# 自动从 GitHub 下载最新静态编译二进制，打包成 ipk
#


set -e

PKG="$1"
OUT="${2:-.}"

if [ -z "$PKG" ]; then
  echo "Usage: $0 <package> [output_dir]"
  echo "Packages: xray, hysteria, geoview, sing-box, all"
  exit 1
fi

if [ ! -d "$OUT" ]; then
  echo "ERROR: output dir not found: $OUT"
  exit 1
fi

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
      # TAG is like "app%2Fv2.9.1", extract version "v2.9.1" -> "2.9.1"
      VER=$(echo "$TAG" | sed 's|app%2Fv||' | tr '%/' '-')
      echo "=== hysteria @ $VER ==="
      # try avx first, fall back to non-avx
      URL="https://github.com/apernet/hysteria/releases/download/$TAG/hysteria-linux-amd64-avx"
      if ! curl -sIL "$URL" | grep -q "^HTTP.*200"; then
        URL="https://github.com/apernet/hysteria/releases/download/$TAG/hysteria-linux-amd64"
      fi
      curl -sL "$URL" -o "$WORK/hysteria"
      chmod +x "$WORK/hysteria"
      FILE="$WORK/hysteria"
      ;;

    geoview)
      # 尝试从页面提取版本号
      VER=$(curl -sL "https://github.com/snowie2000/geoview/releases" | grep -o 'releases/tag/[^"]*' | head -1 | sed 's|releases/tag/||')
      if [ -z "$VER" ]; then
        VER="0.2.6"
      fi
      echo "=== geoview @ $VER ==="
      # geoview 版本不带 v 前缀
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
      # find the extracted directory
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

  # 打包
  cp "$FILE" "$WORK/data/usr/bin/$PKG_NAME"

  cat > "$WORK/control/control" << EOF
Package: $PKG_NAME
Version: $VER
Architecture: $ARCH
Maintainer: vee
Description: $PKG_NAME binary package
EOF

  tar -C "$WORK/control" -czf "$WORK/control.tar.gz" .
  tar -C "$WORK/data" -czf "$WORK/data.tar.gz" .
  printf '2.0\n' > "$WORK/debian-binary"

  IPK="$OUT_DIR/${PKG_NAME}_${VER}_${ARCH}.ipk"
  tar -czf "$IPK" -C "$WORK" debian-binary control.tar.gz data.tar.gz

  echo ""
  echo "Done: $IPK"
  echo "Size: $(du -sh "$IPK" | cut -f1)"
  echo "----------------------------------------"

  # 清理
  rm -rf "$WORK"
  return 0
}

if [ "$PKG" = "all" ]; then
  echo "========================================"
  echo "开始全面打包所有包..."
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
  echo "全面打包完成！"
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

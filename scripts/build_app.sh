#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AutoLockMyMac"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/LockMyPC.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

# Keep compiler caches inside the project so builds also work in restricted
# environments where ~/.cache is not writable.
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

# IDE 的 SwiftPM/语言服务会长期占用默认的 .build 目录锁，导致打包时报
# "Another instance of SwiftPM is already running"。这里使用独立的 scratch
# 目录，避免与 IDE 抢锁。可通过环境变量 SCRATCH_PATH 覆盖。
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT_DIR/.build-release}"

swift build -c release --product "$APP_NAME" --scratch-path "$SCRATCH_PATH" >/dev/null
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 用源 PNG 生成 macOS 应用图标（AppIcon.icns）。Info.plist 里通过
# CFBundleIconFile=AppIcon 引用它。
ICON_SRC="$ROOT_DIR/Sources/AutoLockMyMac/Assets/images/lockicon.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET_DIR")"
else
    echo "警告：未找到图标源文件 $ICON_SRC，应用将使用系统默认图标。" >&2
fi

# CoreBluetooth 需要应用带有代码签名，系统才会弹出并记住蓝牙权限授权。
# 这里使用 ad-hoc 签名（-）即可让 TCC 按 bundle id 识别本应用。
# 清理扩展属性，否则 codesign 会因 "resource fork / detritus" 报错。
# 注意：若项目位于 iCloud Drive（如 ~/Documents）同步目录下，系统会在清理属性和
# 签名之间的极短窗口里把 com.apple.FinderInfo 写回，造成竞态。这里用重试循环来兜底。
signed=0
for attempt in 1 2 3 4 5; do
    xattr -rc "$APP_DIR" 2>/dev/null || true
    xattr -rd com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
    if codesign --force --sign - "$APP_DIR" 2>/dev/null; then
        # Finder/iCloud may put FinderInfo back immediately after signing.
        # Removing that directory-only metadata does not alter signed contents;
        # verify the finished bundle before accepting the attempt.
        sleep 1
        xattr -rd com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
        if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
            signed=1
            break
        fi
    fi
done

if [ "$signed" -ne 1 ]; then
    echo "错误：多次尝试后仍无法完成代码签名（可能是 iCloud 同步竞态）。请稍后重试。" >&2
    exit 1
fi

rm -rf "$LEGACY_APP_DIR"

echo "Created: $APP_DIR"
echo "提示：ad-hoc 签名的应用 spctl 会显示 rejected，这是正常的，本机仍可运行。"
echo "若首次启动被拦，请在「系统设置 → 隐私与安全性」中点「仍要打开」。"

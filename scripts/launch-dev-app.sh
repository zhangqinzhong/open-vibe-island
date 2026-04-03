#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/arm64-apple-macosx/release"
app_binary="$build_root/VibeIslandApp"
hooks_binary="$build_root/VibeIslandHooks"
setup_binary="$build_root/VibeIslandSetup"
brand_script="$repo_root/scripts/generate_brand_icons.py"
brand_icon="$repo_root/Assets/Brand/VibeIsland.icns"
bundle_dir="$HOME/Applications/Vibe Island OSS Dev.app"
plist_path="$bundle_dir/Contents/Info.plist"
bundle_binary="$bundle_dir/Contents/MacOS/VibeIslandApp"

cd "$repo_root"

swift build -c release --product VibeIslandApp
swift build -c release --product VibeIslandHooks
swift build -c release --product VibeIslandSetup

python3 "$brand_script"
"$setup_binary" install --hooks-binary "$hooks_binary"

mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$app_binary" "$bundle_binary"
cp "$brand_icon" "$bundle_dir/Contents/Resources/VibeIsland.icns"
chmod +x "$bundle_binary"

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VibeIslandApp</string>
    <key>CFBundleIdentifier</key>
    <string>app.vibeisland.oss.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>VibeIsland</string>
    <key>CFBundleName</key>
    <string>Vibe Island OSS Dev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSEnvironment</key>
    <dict>
        <key>VIBE_ISLAND_HOOKS_BINARY</key>
        <string>$hooks_binary</string>
    </dict>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

pkill -f "$bundle_binary" >/dev/null 2>&1 || true
open -na "$bundle_dir"

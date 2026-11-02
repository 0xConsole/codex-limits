#!/bin/sh
# Builds dist/Codex Limits.app, the macOS menu-bar app, with an ad-hoc signature.
# Set ARCHS="arm64 x86_64" for a universal build.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

version=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/CodexLimitsCore/AppPaths.swift)
arch_flags=""
for arch in ${ARCHS:-}; do
    arch_flags="$arch_flags --arch $arch"
done

# shellcheck disable=SC2086
swift build -c release --product CodexLimits $arch_flags
# shellcheck disable=SC2086
bin_dir=$(swift build -c release --product CodexLimits $arch_flags --show-bin-path)

app_dir="$repo_dir/dist/Codex Limits.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

rm -rf "$app_dir"
mkdir -p "$macos_dir"
cp "$bin_dir/CodexLimits" "$macos_dir/CodexLimits"

cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CodexLimits</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex-limits</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Limits</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Limits</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Codex Limits can read a recent OpenAI verification code from Apple Mail and fill it into Arc during account sign-in.</string>
</dict>
</plist>
PLIST

chmod +x "$macos_dir/CodexLimits"
codesign --force --deep --sign - "$app_dir" >/dev/null

# Replacing the bundle does not stop a copy that is already running.
if pgrep -x CodexLimits >/dev/null 2>&1; then
    echo "Codex Limits is still running the previous build. Quit it from its menu before opening this one." >&2
fi
echo "$app_dir"

#!/bin/zsh
set -eu
cd "${0:A:h:h}"
output_dir="${ETHERLINK_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output_dir"
source ./scripts/toolchain.sh
"$ETHERLINK_SWIFT" build -c release --product EtherLink --arch arm64 --arch x86_64
binary_dir="$("$ETHERLINK_SWIFT" build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="$output_dir/EtherLink.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/EtherLink" "$app/Contents/MacOS/EtherLink"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EtherLink</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.EtherLink</string>
<key>CFBundleName</key><string>EtherLink</string>
<key>CFBundleDisplayName</key><string>EtherLink</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>13</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect securely to your other Mac using only the Ethernet adapter you select.</string>
</dict></plist>
PLIST
# A fixed signing identity keeps the code requirement stable across builds, so macOS
# Accessibility/Input Monitoring grants survive updates. Ad-hoc signing changes it every build.
identity="${ETHERLINK_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -p codesigning | awk '/"EtherLink Local Signing"/ {print $2; exit}')"
fi
if [[ -z "$identity" ]]; then
    print -u2 'WARNING: "EtherLink Local Signing" identity not found; signing ad hoc. Privacy permissions will need re-granting after installing this build.'
    identity=-
fi
codesign --force --sign "$identity" "$app"
codesign -d -r- "$app" 2>&1 | tail -1
# Build copies share the installed app's bundle ID; keep System Settings from resolving to them.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
ditto -c -k --keepParent "$app" "$output_dir/EtherLink.zip"
printf 'Built %s\n' "$app"

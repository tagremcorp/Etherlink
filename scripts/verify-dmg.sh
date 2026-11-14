#!/bin/zsh
set -eu
cd "${0:A:h:h}"
output_dir="${ETHERLINK_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output_dir"
mount_dir="$(mktemp -d "$output_dir/dmg-mount.XXXXXX")"
mounted=0
cleanup() {
    if (( mounted )); then hdiutil detach "$mount_dir"; fi
    rmdir "$mount_dir"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$output_dir/EtherLink.dmg"
mounted=1
codesign --verify --deep --strict "$mount_dir/EtherLink.app"
plutil -lint "$mount_dir/EtherLink.app/Contents/Info.plist"
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
[[ -f "$mount_dir/Install EtherLink.txt" ]]
lipo -info "$mount_dir/EtherLink.app/Contents/MacOS/EtherLink"
print 'PASS: mounted DMG contains a valid signed universal app, Applications shortcut, and install instructions.'

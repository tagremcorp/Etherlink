#!/bin/zsh
# Source this file to use full Xcode for this project without changing xcode-select.
export DEVELOPER_DIR="${ETHERLINK_DEVELOPER_DIR:-${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    print -u2 "Full Xcode was not found at $DEVELOPER_DIR. Install Xcode or set ETHERLINK_DEVELOPER_DIR."
    return 1
fi
export ETHERLINK_SWIFT="$(/usr/bin/xcrun --find swift)"

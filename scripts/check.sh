#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source ./scripts/toolchain.sh
"$ETHERLINK_SWIFT" run LinkCoreChecks
if (( $# == 2 )); then
    "$ETHERLINK_SWIFT" build --product EtherLink
    python3 scripts/test-transport.py "$1" "$2"
elif (( $# != 0 )); then
    print -u2 'Usage: ./scripts/check.sh [Ethernet-interface local-IPv4]'
    exit 2
fi

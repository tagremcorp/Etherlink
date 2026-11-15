#!/bin/zsh
set -eu
cd "${0:A:h:h}"
output_dir="${ETHERLINK_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output_dir"
./scripts/build-app.sh
staging="$(mktemp -d "$output_dir/dmg-staging.XXXXXX")"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Packaging re-registers build copies; unregister them so only the installed app is known.
trap '"$lsregister" -u "$staging/EtherLink.app" 2>/dev/null; rm -rf "$staging"; "$lsregister" -u "$output_dir/EtherLink.app" 2>/dev/null || true' EXIT
# Keep staging local and isolated; ditto preserves the signed app bundle.
ditto "$output_dir/EtherLink.app" "$staging/EtherLink.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/Install EtherLink.txt" <<'TEXT'
EtherLink — Keyboard and mouse sharing prototype 0.4.1

1. Drag EtherLink.app into Applications, then eject this disk image.
2. Open EtherLink from Applications on both Macs.
3. Select the Ethernet adapter on each Mac.
4. On each Mac, enter the OTHER Mac's Ethernet IPv4 address (for example 192.168.50.2 on the Mac whose own address is 192.168.50.1, and the reverse).
5. Choose Listen on one Mac and Connect on the other.
6. Generate a pairing key on one Mac, enter the same key on the other, and optionally save it to Keychain on each.
7. Start listening, then connect. Allow local-network access/incoming connections if macOS asks.
8. Leave Wi-Fi enabled. Verify heartbeats, then unplug Ethernet and confirm both apps disconnect without Wi-Fi fallback.

9. A "Which Mac receives the keyboard and mouse?" prompt appears on both Macs. Answer on EITHER screen, choosing this Mac or the other Mac by name/IP. The pair assigns exactly one source and one receiver. Monitor-connected devices belong to whichever Mac receives their USB input. Both Macs must acknowledge the choice before sharing can start.
10. Click Enable sharing on both Macs. Allow Accessibility and Input Monitoring. The app keeps checking and enables sharing when macOS reports access. If old enabled entries are rejected after an update, remove EtherLink from both lists and re-add the installed /Applications/EtherLink.app, then reopen it.
11. On the Keyboard Mac, press Control-Option-F8 to switch control (Fn may also be required). Use Record custom shortcut or Use preset to change the switching shortcut. Control-Option-Escape always returns control to the Keyboard Mac. Buttons are also provided in the app.

Save the pairing key to Keychain on both Macs for automatic reconnection after app restart. Auto-reconnect polls every five seconds, only through the selected Ethernet adapter. Disconnect/Cancel stops automatic retries.

Install version 0.4.1 on BOTH Macs. 0.3.x and 0.4.0 can still pair with it, but automatic detection of the shared display and the push setting for the return edge need 0.4.1 on both. Closing the EtherLink window keeps it running in the menu bar (cable icon at the top of the screen); use Quit EtherLink there to stop it. Use "Choose keyboard and mouse source" on either Mac to change the choice later. Reconfiguration immediately returns input locally and pauses forwarding. Confirmed choices restore automatically after reconnect. Choose later dismisses both prompts and leaves sharing paused. Quit the old app before replacing it. Only run the installed copy from Applications.

Screen-edge switching: on the keyboard Mac set "Other Mac's screen is" (for two PBP halves side by side, "To the right" on the Mac shown on the left), then push the pointer against that edge and keep pushing. On a Mac with more than one display, "Display next to the other Mac" limits switching to that display's edge; Automatic picks the monitor both Macs are plugged into when it can. "Push needed to switch" sets how firm the push is. The corners of an edge never switch. Typed characters match across different keyboard layouts. You can type into password fields on the receiving Mac. The login window, a locked screen and FileVault startup still need that Mac's own keyboard.

Requires macOS 13 or later. Universal app for Intel and Apple Silicon; Intel execution and older macOS versions have not been tested.

This development app is signed with a local self-signed certificate ("EtherLink Local Signing") and is not notarized. From 0.3.2 on, privacy permissions carry over to later versions; grant them once after installing 0.3.2. If macOS blocks it after you try opening it, go to System Settings > Privacy & Security > Open Anyway. A Developer ID-signed, notarized release requires the developer's Apple signing credentials.
TEXT
# A compressed read-only image with a checksum; overwrites only this build output.
hdiutil create -ov -volname EtherLink -srcfolder "$staging" -format UDZO "$output_dir/EtherLink.dmg"
hdiutil verify "$output_dir/EtherLink.dmg"
print "Built $output_dir/EtherLink.dmg"

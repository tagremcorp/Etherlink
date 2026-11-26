# Testing record

What has been tested, how, and what still has not. Hardware results come from the reference desk: two Apple Silicon Macs on macOS 27, joined by a direct Ethernet cable, both shown on an LG 28MQ780-B DualUp in PBP mode, with Wi-Fi left on throughout.

## Automated checks

`./scripts/check.sh` runs 15 check groups in a standalone executable (no XCTest required):

- IPv4 validation and pairing-key format and decoding.
- Message framing with the transport’s real decoder: fragmented and coalesced frames, malformed JSON, oversized frames, version mismatch, replayed or out-of-order sequence numbers.
- Heartbeat watchdog expiry and reset.
- Input packets: physical keycodes, payload validation, held key/modifier/button release on disconnect.
- Motion coalescing: moves, same-button drags and mid-gesture scrolls merge; keys, clicks and scroll begin/end never do; merged deltas stay within protocol limits.
- Switching shortcuts: defaults, custom combinations, rejection of plain typing keys and the reserved emergency shortcut.
- Screen edges: outer-edge detection with three displays (shared edges never cross), edge positions, entry points, corners, and the push: threshold, reset, slow drift, a pointer thrown at the edge, sustained pushes and firmness levels.
- Shared display: automatic detection from both Macs’ monitor identities, manual choice, a choice whose system ID changed, disconnected and identical monitors, peers that report no displays.
- Keyboard layouts: swapped letters (QWERTY/QWERTZ), symbols on different keys and modifiers, keypad preference, unmappable characters.
- New message fields (edge, position, key text, reason, display list, push level, activity, lock state): round trip, validation, and decoding of 0.3.x messages without them.
- Keyboard-source negotiation: choice from either Mac, simultaneous conflicting choices, stale acknowledgements, cancellation, restoring and rejecting saved choices.

## Two-process tests on one Mac

These run two copies of the app’s headless probe against one Mac’s own Ethernet address. They prove socket, binding and TLS behaviour, not cable traffic between two Macs.

- `check.sh <iface> <ip>`: listener bound to the exact address (never a wildcard), matching keys exchange authenticated heartbeats, wrong keys fail TLS on both sides, connecting before the listener is ready recovers by itself, automatic reconnection after the peer restarts, and a listener that keeps listening after a stray, non-EtherLink connection.
- `test-role-pair.py`: both peers show the source prompt and confirm opposite roles, whichever side answers, including both at once.
- `test-ui-stall.py`: TLS and heartbeats survive eight seconds of a blocked UI thread.
- A second listener on a port already in use reports it once and stops instead of retrying forever.

## Real keyboard layouts

`EtherLink --layout-check` reads macOS’s actual layouts: every printable character on the current layout (267 on a US layout) resolves back to a key that types it, and all 98 main-keyboard characters of a US layout type the same character through the German QWERTZ layout (for example z on key 16, @ as Option-L).

## Confirmed on the two-Mac desk

- Pairing over the selected Ethernet adapter with Wi-Fi enabled.
- Unplugging the cable drops the connection with no Wi-Fi fallback; replugging reconnects.
- Accessibility and Input Monitoring grants, including recovery from stale grants (see below).
- Switching control with the shortcut and forwarding keyboard and mouse to the other Mac.
- Stable signing: an update signed with the same certificate kept its permissions with no re-grant.
- v0.4.0 screen-edge switching between the two Macs, with 0.4.0 installed on both.
- v0.4.1 edge switching on a keyboard Mac with three displays: only the display next to the other Mac switches.
- v0.4.2 hiding the local pointer while the other Mac is controlled. In v0.3.3 to v0.4.1 the pointer stayed visible and moved, because macOS only lets the frontmost app hide or freeze it.

## Not yet verified on hardware

- Behaviour under sustained fast input (drag and scroll coalescing under real load), and latency.
- The menu bar controls and window-close behaviour introduced in v0.3.3.
- v0.4.1 push levels and corner exclusion by feel, and whether the LG reports the same identity to both Macs in PBP mode (automatic detection).
- v0.4.3 keeping the receiving Mac awake: that its display no longer sleeps and locks while it is controlled or while the keyboard Mac is in use, that switching to it wakes a sleeping display, whether the screen saver is also held off, and the locked-Mac padlock and message.
- v0.4.0 layout matching between two Macs, typing into a password field on the receiving Mac, and the locked-screen and secure-input messages.
- Sleep and wake, adapter removal and address changes during active control.
- Display reconfiguration while forwarding.
- Intel Macs and macOS versions before 27.

## Lesson learned: stale privacy grants

With ad-hoc signing, every build has a different code hash, so macOS treats each version as a new app. After an update, Accessibility and Input Monitoring toggles stayed on but were rejected (“Failed to match existing code requirement” in the TCC log). Re-adding the app did not help while several copies with the same bundle ID were registered with Launch Services: System Settings saved the grant against an old build.

The fix was to unregister stale copies, reset only EtherLink’s entries with `tccutil reset … local.EtherLink`, re-add `/Applications/EtherLink.app`, and relaunch. From v0.3.2, builds are signed with a fixed self-signed certificate, so the code requirement (`identifier "local.EtherLink" and certificate leaf = …`) no longer changes between versions, and the build scripts unregister their own build copies.

## Lesson learned: edges belong to a display, not a desktop

v0.4.0 treated “the other Mac is below” as a side of the whole desktop, so on a keyboard Mac with three monitors side by side, the bottom of every monitor switched control. It was only tried on a single-display Mac before release. From v0.4.1 the edge belongs to one display: the one chosen in settings, or the monitor both Macs report being plugged into.

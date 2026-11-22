# EtherLink design

The original design brief for EtherLink: Mac-to-Mac keyboard and mouse sharing over direct Ethernet.

**Current status (v0.4.2):** milestones 1 and 2 are implemented and in use on two Macs. Milestone 3 is implemented in a simpler form than planned below: one configured side per pair, crossing only at the outer edge of the display next to the other Mac (chosen by hand, or detected as the monitor both Macs report), with a sustained-push requirement, corners excluded and a matching entry position (no per-display edge segments yet). Milestone 4 is partly covered (cable loss, reconnection, sleep, secure input). Milestone 5 is partly done (DMG packaging, stable self-signing); launch at login is not implemented. See [TESTING.md](TESTING.md).

## Goal

Build a native macOS app that lets one keyboard and mouse control two Macs connected by a direct Ethernet cable.

The reference desk has three monitors, including an LG 28MQ780-B DualUp. One LG will use its built-in Picture-by-Picture mode to display an input from each Mac simultaneously. The app must support moving control between those two visible halves, as well as the other monitors.

Both Macs must retain their independent Wi-Fi internet connections. No router changes, internet sharing, or LG software should be required.

## Intended experience

The same app runs on both Macs:

- **Keyboard Mac:** the Mac with the physical keyboard and mouse.
- **Other Mac:** the Mac receiving forwarded input.

Initial setup:

1. Choose the Ethernet adapter on each Mac.
2. Enter the other Mac’s Ethernet IP address.
3. Pair the Macs securely.
4. Grant the required macOS permissions.
5. Choose a shortcut for switching control.
6. Configure where the visible screens meet.

During use:

- The keyboard and mouse control one Mac at a time.
- A shortcut switches control immediately.
- After screen mapping is configured, moving through a chosen screen edge transfers control to the other Mac.
- Keyboard shortcuts, dragging, scrolling and modifier keys follow the active Mac.
- An emergency shortcut always returns control to the Keyboard Mac.
- If the connection fails, the Keyboard Mac immediately regains local control.

## Scope and boundaries

The first release supports two Macs with users already logged in.

The LG monitors perform PBP through their own controls. The app does not split a video signal or combine the Macs’ desktops.

Do not include monitor input switching, screen streaming, file transfer or clipboard synchronization in the first release. Add those only after input sharing works reliably.

Do not promise control of FileVault startup, login screens or protected input contexts. Detect unsupported states where possible and report them clearly.

Do not modify LG’s installation or database.

## Technical approach

Build one native Swift app using SwiftUI for setup and AppKit/Core Graphics where needed for input and display handling.

Use:

- **Network.framework** for connections explicitly constrained to the selected Ethernet interface and local address.
- **Core Graphics event taps** to capture and suppress local input while forwarding.
- **Core Graphics event posting** to reproduce input on the receiving Mac.
- **Keychain** for stored pairing credentials.
- macOS display APIs for screen enumeration, coordinates and display-change notifications.

Confirm the available macOS version, development tools and signing setup before choosing the deployment target.

Keep networking, input capture, input injection, screen mapping and the interface separate enough to test independently.

## Networking requirements

This is a central requirement, not a preference setting.

- Let the user select a specific adapter and inspect its current IPv4 address.
- Bind listeners and outgoing connections to that adapter.
- Connect directly to the peer’s Ethernet IP.
- Never silently switch to Wi-Fi.
- Show the actual local address, remote address and interface used by the established connection.
- If the selected adapter disappears or its address changes, stop forwarding input and show a clear connection error.
- Do not change macOS service order, routes or internet settings.

Discover or ask for each Mac’s Ethernet address; never hard-code them.

Use authenticated, encrypted transport with explicit first-time pairing. Use established platform cryptography rather than a custom encryption scheme.

A reliable ordered connection is sufficient for the first implementation. Coalesce stale mouse-movement updates so they cannot build up behind other traffic.

## Input handling

Forward:

- Key down and key up.
- Modifier changes, including Command, Option, Control and Shift.
- Mouse movement.
- Primary, secondary and additional supported mouse buttons.
- Scrolling.
- Dragging.

Use keyboard event information appropriate for shortcuts and key state, rather than treating every key as text. Define the behavior when the two Macs use different keyboard layouts.

While controlling the Other Mac:

- Suppress the corresponding local input.
- Preserve access to the emergency return shortcut.
- Prevent forwarded events from being captured and sent back again.
- Manage cursor visibility and position consistently.
- Avoid applying mouse acceleration twice.

Track pressed keys and buttons. Release outstanding state on disconnect, control transfer, sleep or an application failure detected by the peer.

Use a heartbeat/watchdog so a lost connection cannot leave the local user unable to control their Mac.

## Screen mapping and PBP

Do not assume that the three physical monitors form a simple rectangle or that macOS knows how the two PBP halves are arranged on the desk.

Build a setup view showing the displays reported by each Mac. Allow the user to identify them and connect selected edges.

Example:

> Leaving the right edge of the Keyboard Mac’s display in the left PBP half enters the left edge of the Other Mac’s display in the right PBP half.

Support:

- Different resolutions and scaling.
- Displays with negative desktop coordinates.
- Multiple displays on either Mac.
- Crossing only designated portions of an edge.
- Normalized entry positions along the connected edges.
- A small crossing threshold or hysteresis to prevent immediate bouncing back.

Use persistent display identifiers where available. Revalidate mappings after display changes, PBP changes, sleep or unplugging a monitor.

The first prototype should use shortcut switching. Add edge crossing after basic forwarding is dependable.

## Implementation milestones

### 1. Prove the Ethernet connection

Build a minimal app on each Mac that pairs, exchanges heartbeat messages and displays the actual connection path.

Acceptance:

- Both Macs keep Wi-Fi enabled.
- Traffic between the apps uses the direct Ethernet cable.
- Unplugging that cable breaks the app connection.
- The app does not reconnect over Wi-Fi.
- Internet access remains unchanged.

Do not proceed until this works on the actual Macs.

### 2. Forward input with a switching shortcut

Add mouse, keyboard, buttons and scrolling. Include permission guidance and an emergency return shortcut.

Acceptance:

- One physical keyboard and mouse operate either Mac.
- Local input is suppressed during remote control.
- Common shortcuts and dragging work.
- Disconnecting the cable restores local control and clears held keys/buttons.

### 3. Add multiple-display and PBP mapping

Add display identification, edge mappings and cursor transitions.

Acceptance:

- Control crosses between the two PBP halves in the expected direction.
- Other displays remain usable.
- Different scaling and display positions do not produce cursor jumps or traps.

### 4. Handle interruptions

Test sleep/wake, locking, permission removal, app restarts, display changes and network changes.

Acceptance:

- Failures restore local control.
- Reconnection requires the selected Ethernet path and trusted peer.
- No held keys, hidden cursors or accidental Wi-Fi fallback remain after recovery.

### 5. Package for normal use

Produce an installable app for both Macs, with clear setup instructions, connection status and an optional launch-at-login setting.

Use stable signing where available so updates do not unnecessarily disrupt macOS permissions. Document any remaining signing or distribution limitations.

## Verification and diagnostics

Automate tests for protocol parsing, connection/control state transitions, pressed-key cleanup and coordinate mapping.

Perform real two-Mac tests for event capture, injection, adapter binding and the desk’s display layout. Tests alone cannot establish that the hardware workflow works.

Diagnostics should record connection state, selected interfaces and errors. Do not record typed text or raw keystroke histories.

Measure responsiveness during real use, including sustained mouse movement, scrolling and dragging. Report measurements and remaining limitations rather than claiming untested performance.

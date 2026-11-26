import SwiftUI
import AppKit
import Combine
import LinkCore

// Explicit alias selects the property wrapper on SDKs that also declare a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--probe") { Probe.run() }
        else if CommandLine.arguments.contains("--layout-check") { Probe.layoutCheck() }
        else { EtherLinkApp.main() }
    }
}

/// EtherLink keeps running from the menu bar after its window closes. Quitting (menu bar or ⌘Q)
/// triggers LinkSession's willTerminate observer, which restores local input and disconnects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct EtherLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = LinkSession()
    var body: some Scene {
        Window("EtherLink", id: "main") { SetupView(session: session, input: session.input) }
            .windowStyle(.titleBar)
            .defaultSize(width: 680, height: 740)
        MenuBarExtra {
            MenuBarMenu(session: session, input: session.input)
        } label: {
            MenuBarLabel(session: session, input: session.input)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu bar icon reflects the link state, and reopens the window when the pair needs a
/// keyboard-source answer while the window is closed (the label view is always alive).
struct MenuBarLabel: View {
    @ObservedObject var session: LinkSession
    @ObservedObject var input: InputController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: input.remote ? "arrow.left.arrow.right.circle.fill"
              : input.peerLocked ? "lock.fill"
              : session.authenticated ? "cable.connector.horizontal" : "network.slash")
            .accessibilityLabel(input.remote ? "EtherLink: controlling the other Mac"
                                : input.peerLocked ? "EtherLink: the other Mac is locked"
                                : session.authenticated ? "EtherLink: connected" : "EtherLink: not connected")
            .onChange(of: input.rolePromptVisible) { visible in
                if visible { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var session: LinkSession
    @ObservedObject var input: InputController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(session.authenticated ? "Connected to \(input.peerName)" : (session.reconnecting || session.running ? "Connecting…" : "Not connected"))
        if session.authenticated {
            Text(input.roleConfirmed ? (input.keyboardMac ? "This Mac is the keyboard source" : "This Mac receives input") : "Keyboard source not chosen")
        }
        if input.peerLocked { Text("\(input.peerName) is locked — unlock it there") }
        Divider()
        if input.keyboardMac {
            Button(input.remote ? "Return Control to This Mac" : "Switch to \(input.peerName)") { input.toggle() }
                .disabled(!input.remote && (!input.roleConfirmed || !session.authenticated || !input.enabled))
        } else {
            Button("Return Control to Keyboard Mac") { input.returnLocal() }.disabled(!input.enabled)
        }
        Button(input.sharingRequested ? "Disable Sharing" : "Enable Sharing") {
            if input.sharingRequested { input.disable() } else { input.enable() }
        }
        if session.authenticated {
            Button("Choose Keyboard and Mouse Source…") { openMain(); input.requestRoleSetup() }
        }
        Divider()
        Button("Open EtherLink") { openMain() }
        Button("Quit EtherLink") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupView: View {
    @ObservedObject var session: LinkSession
    @ObservedObject var input: InputController
    @AppStorage("shortcutKey") private var shortcutKey = 100
    @AppStorage("shortcutModifiers") private var shortcutModifiers = 3
    @AppStorage("shortcutKeyName") private var shortcutKeyName = ""
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("edgeSide") private var edgeSide = ""
    @AppStorage("edgeDisplay") private var edgeDisplay = ""
    @AppStorage("edgePush") private var edgePush = EdgePushLevel.medium.rawValue
    @AppStorage("translateLayouts") private var translateLayouts = true
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("adapter") private var adapterID = ""
    @AppStorage("peer") private var peer = ""
    @AppStorage("listen") private var listen = true
    @ViewState<String> private var key = ""
    @ViewState<String> private var notice = ""
    @ViewState<Bool> private var showKey = false
    @ViewState<Bool> private var loadingSavedKey = false
    @ViewState<String> private var lookedUpPeer = ""
    @ViewState<String> private var automaticStatus = ""
    @ViewState<Bool> private var savingKey = false
    // Held in State so redraws do not replace the publisher and restart its 5-second countdown.
    @ViewState private var automaticTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @FocusState private var peerFocused: Bool
    @ViewState<Bool> private var peerDirty = false
    @ViewState<Date> private var peerEditedAt = Date.distantPast
    private var adapter: Adapter? { session.adapters.first { $0.id == adapterID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "cable.connector.horizontal").font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("EtherLink").font(.largeTitle.bold())
                        Text("Direct Ethernet · Mac to Mac").foregroundStyle(.secondary)
                        Text(versionLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text("Input sharing prototype").font(.caption.bold()).padding(8).background(.blue.opacity(0.12), in: Capsule())
                }
                Text("One keyboard and mouse, two Macs. Pair over your selected Ethernet adapter, then enable sharing on both Macs.")
                GroupBox("1. Choose the cable connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Ethernet adapter").font(.callout)
                                Text("Peer IP address").font(.callout)
                            }
                            GridRow {
                                Picker("Ethernet adapter", selection: $adapterID) {
                                    Text("Select an adapter…").tag("")
                                    ForEach(session.adapters) { item in Text(item.label).tag(item.id) }
                                }.labelsHidden().accessibilityLabel("Ethernet adapter")
                                    .frame(minWidth: 230, maxWidth: .infinity)
                                TextField("Peer IP address", text: $peer, prompt: Text("Other Mac’s IPv4"))
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Peer IP address").frame(width: 170)
                                    .focused($peerFocused)
                                    .onSubmit { peerDirty = false; attemptAutomaticConnection() }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if session.adapters.isEmpty { Text("No Ethernet adapter with an IPv4 address found. Connect the cable and check System Settings → Network.").foregroundStyle(.orange) }
                        Text("Only the selected adapter and local address are allowed. Wi-Fi is never a fallback.").font(.caption).foregroundStyle(.secondary)
                        Picker("This Mac", selection: $listen) {
                            Text("Listen").tag(true)
                            Text("Connect").tag(false)
                        }.pickerStyle(.segmented)
                        Text("Choose Listen on one Mac and Connect on the other. After allowing network access, setup continues automatically—no second click is needed.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(session.running)
                GroupBox("2. Pair the two Macs") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Generate a key on one Mac, then enter the same key on the other. Transfer it privately; anyone with the key can authenticate.").font(.callout)
                        HStack {
                            if showKey { TextField("Pairing key", text: $key).font(.system(.caption, design: .monospaced)) }
                            else { SecureField("64-character pairing key", text: $key) }
                            Toggle("Show", isOn: $showKey).toggleStyle(.checkbox)
                        }
                        HStack {
                            Button("Generate key") { perform { key = try PairingStore.generate(); showKey = true; notice = "New key generated. Save it on both Macs after transferring it privately." } }
                            Button("Save to Keychain") { savePairingKey() }
                            Button("Load saved key") { loadPairingKey(force: true) }
                            Button("Forget") {
                                let target = peer
                                session.disconnect(); key = ""; lookedUpPeer = target
                                DispatchQueue.global(qos: .userInitiated).async {
                                    do { try PairingStore.forget(peer: target)
                                        DispatchQueue.main.async { notice = "Saved pairing key removed." }
                                    } catch { DispatchQueue.main.async { notice = error.localizedDescription } }
                                }
                            }
                        }
                    }.padding(8)
                }.disabled(session.running)
                HStack {
                    Button(listen ? "Start listening" : "Connect over Ethernet") {
                        guard let adapter else { notice = "Select an available Ethernet adapter."; return }
                        perform {
                            try requirePeer()
                            guard peer != adapter.address else { throw LinkError.invalid("Enter the other Mac’s address, not this Mac’s address.") }
                            _ = try Validation.secret(key); notice = ""
                            session.start(adapter: adapter, peer: peer, secret: key, listen: listen)
                        }
                    }.accessibilityIdentifier("startConnection").accessibilityLabel(listen ? "Start listening" : "Connect over Ethernet").buttonStyle(.borderedProminent).disabled(session.running)
                    Button(session.authenticated ? "Disconnect" : "Cancel") { session.disconnect() }.accessibilityIdentifier("stopConnection").accessibilityLabel(session.authenticated ? "Disconnect" : "Cancel").disabled(!session.running && !session.reconnecting)
                    Spacer()
                }
                Toggle("Automatically connect and reconnect over Ethernet (every 5 seconds; saves key in Keychain)", isOn: $autoReconnect)
                    .onChange(of: autoReconnect) { value in
                        session.autoReconnectEnabled = value
                        if value { session.armAutomaticConnection(); attemptAutomaticConnection() }
                        session.scheduleReconnect()
                    }
                if !automaticStatus.isEmpty { Text(automaticStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                GroupBox("3. Share keyboard and mouse") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(input.roleSummary).textSelection(.enabled)
                        Button("Choose keyboard and mouse source…") { input.requestRoleSetup() }
                            .accessibilityIdentifier("chooseKeyboardSource")
                            .disabled(!session.authenticated)
                        Text("Answer the prompt on either Mac. The pair assigns one input source and one receiver automatically. Devices plugged into the monitor count as connected to whichever Mac receives the monitor’s USB input.").font(.caption).foregroundStyle(.secondary)
                        Text("Switch control: \(shortcutLabel)").bold()
                        HStack {
                            ShortcutRecorder(onRecorded: { shortcut, name in
                                applyShortcut(shortcut, name: name)
                            }, onError: { notice = $0 }, onRecordingChanged: { active in
                                input.recordingShortcut = active
                            }).frame(width: 260, height: 28)
                            Menu("Use preset") {
                                Button("Control–Option–F8 (default)") { applyShortcut(.defaultShortcut, name: "F8") }
                                Button("Control–Option–F9") { applyShortcut(.init(keyCode: 101, modifiers: 3), name: "F9") }
                                Button("Control–Option–F10") { applyShortcut(.init(keyCode: 109, modifiers: 3), name: "F10") }
                            }.fixedSize()
                        }.disabled(input.remote)
                        Text("Click Record, then press your preferred key combination. Esc cancels. Shortcuts use physical keys; record again if you change keyboard layout. Avoid combinations already used by macOS or other apps.").font(.caption).foregroundStyle(.secondary)
                        Text("Emergency return: Control–Option–Escape. Function keys may also require Fn on Apple keyboards.").font(.caption).bold()
                        Picker("Other Mac’s screen is", selection: $edgeSide) {
                            Text("Off (shortcut only)").tag("")
                            Text("To the left").tag(ScreenSide.left.rawValue)
                            Text("To the right").tag(ScreenSide.right.rawValue)
                            Text("Above").tag(ScreenSide.top.rawValue)
                            Text("Below").tag(ScreenSide.bottom.rawValue)
                        }.frame(maxWidth: 360).accessibilityIdentifier("edgeSide")
                            .onChange(of: edgeSide) { value in input.edgeSide = ScreenSide(rawValue: value) }
                        Text("Set this on the keyboard Mac. Push the pointer against that screen edge and keep pushing to move to the other Mac, and against the facing edge there to come back. The corners of the edge never switch. An edge with another of this Mac’s displays beyond it never switches either.").font(.caption).foregroundStyle(.secondary)
                        if input.displays.count > 1 || !edgeDisplay.isEmpty {
                            Picker("Display next to the other Mac", selection: $edgeDisplay) {
                                Text("Automatic").tag("")
                                ForEach(input.displays) { display in Text(display.name).tag(display.choice.stored) }
                                if !edgeDisplay.isEmpty, !input.displays.contains(where: { $0.choice.stored == edgeDisplay }) {
                                    Text("Chosen display (not connected)").tag(edgeDisplay)
                                }
                            }.frame(maxWidth: 360).accessibilityIdentifier("edgeDisplay")
                                .onChange(of: edgeDisplay) { value in input.edgeDisplayChoice = DisplayChoice(stored: value) }
                            Text("Only this display’s edge switches control. Set it on each Mac that has more than one display.").font(.caption).foregroundStyle(.secondary)
                            if !input.edgeDisplayNote.isEmpty {
                                Text(input.edgeDisplayNote).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("edgeDisplayNote")
                            }
                        }
                        Picker("Push needed to switch", selection: $edgePush) {
                            Text("Light").tag(EdgePushLevel.light.rawValue)
                            Text("Medium").tag(EdgePushLevel.medium.rawValue)
                            Text("Firm").tag(EdgePushLevel.firm.rawValue)
                        }.frame(maxWidth: 360).accessibilityIdentifier("edgePush")
                            .onChange(of: edgePush) { value in input.pushLevel = EdgePushLevel(rawValue: value) ?? .medium }
                        Text("Set this on the keyboard Mac; it applies in both directions. Top and bottom edges always need a longer push than the sides, because the menu bar and Dock are there.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Match typed characters across keyboard layouts", isOn: $translateLayouts)
                            .onChange(of: translateLayouts) { value in input.translateLayouts = value }
                        Text("Set this on the keyboard Mac. Each key types the character it shows on this Mac’s layout, even if the other Mac uses a different layout, and shortcuts such as ⌘Z follow the character. Turn it off to send physical key positions instead.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Keep this Mac awake while the keyboard Mac is in use", isOn: $keepAwake)
                            .onChange(of: keepAwake) { value in input.keepAwake = value }.accessibilityIdentifier("keepAwake")
                        Text("Set this on the Mac that receives input. Its display stays on, so it does not sleep and lock, while you are working at the keyboard Mac. It always stays awake while you control it. A locked Mac can only be unlocked with its own keyboard, Touch ID or Apple Watch.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(input.sharingRequested ? "Disable sharing" : "Enable sharing") {
                                if input.sharingRequested { input.disable() } else { input.enable() }
                            }.accessibilityIdentifier("sharingToggle").accessibilityLabel(input.sharingRequested ? "Disable sharing" : "Enable sharing")
                            Button("Switch computer") { input.toggle() }.disabled(!input.roleConfirmed || !input.keyboardMac || !session.authenticated || !input.enabled)
                            Button("Return control") { input.returnLocal() }.disabled(!input.enabled)
                        }
                        HStack {
                            Label("Accessibility: \(input.accessibilityGranted ? "allowed" : "needed")", systemImage: input.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            Label("Input Monitoring: \(input.monitoringGranted ? "allowed" : "needed")", systemImage: input.monitoringGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        }.font(.caption)
                        if input.sharingRequested && !input.enabled {
                            Button("Request missing permissions") { input.requestPermissions() }
                        }
                        Text(input.status).textSelection(.enabled)
                        if input.peerLocked {
                            Label("\(input.peerName) is locked. Unlock it with its own keyboard, Touch ID or Apple Watch.", systemImage: "lock.fill").font(.caption).accessibilityIdentifier("peerLocked")
                        }
                        Text("Enable sharing on both Macs. Allow Accessibility and Input Monitoring when prompted. You can type into password fields on the receiving Mac. While a password field (or Terminal’s Secure Keyboard Entry) is active on the keyboard Mac, macOS hides its keystrokes, so control stays local. The login window, a locked screen and FileVault startup need that Mac’s own keyboard.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if !notice.isEmpty { Text(notice).font(.callout).textSelection(.enabled) }
                GroupBox("Connection status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(session.status, systemImage: session.authenticated ? "lock.shield.fill" : "network")
                            .foregroundStyle(session.authenticated ? .green : .primary)
                        if session.reconnecting { Text("Retrying over the selected Ethernet adapter every five seconds. Cancel stops retries.").foregroundStyle(.secondary) }
                        Text(session.pathDescription).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("Heartbeats received: \(session.received)").font(.callout)
                        Text("Cable test: connect both Macs, leave Wi-Fi on, then unplug Ethernet. The connection must stop. When auto-reconnect is enabled, reconnect the cable and the apps will reconnect over Ethernet automatically. Disconnect stops automatic retries.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                DisclosureGroup("Recent diagnostics") {
                    Text(session.events.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }.padding(24)
        }
        .frame(minWidth: 640, minHeight: 640)
        .sheet(isPresented: Binding(get: { input.rolePromptVisible }, set: { _ in })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Which Mac receives the keyboard and mouse?").font(.title2.bold())
                Text("Choose the Mac that responds directly to your keyboard and mouse. If they are plugged into your monitor, choose the Mac receiving input through the monitor’s USB hub.")
                Text("Answer on either screen. Your choice updates both Macs; exactly one becomes the source.").foregroundStyle(.secondary)
                Button { input.chooseKeyboardSource(here: true) } label: {
                    VStack(alignment: .leading) {
                        Text("Use this Mac’s keyboard and mouse").bold()
                        Text("\(input.localName) · \(input.localAddress)").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("keyboardSourceThisMac")
                Button { input.chooseKeyboardSource(here: false) } label: {
                    VStack(alignment: .leading) {
                        Text("Use the other Mac’s keyboard and mouse").bold()
                        Text("\(input.peerName) · \(input.peerAddress)").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }.buttonStyle(.bordered).accessibilityIdentifier("keyboardSourceOtherMac")
                Button("Choose later") { input.cancelRoleSetup() }.keyboardShortcut(.cancelAction)
                Text("Sharing stays paused until both Macs confirm the assignment. Keep the monitor’s USB/KVM assignment on the source Mac; you can change the source later from either screen.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 490)
                .interactiveDismissDisabled()
        }
        .onAppear {
            let savedShortcut = SwitchShortcut(keyCode: UInt16(clamping: shortcutKey), modifiers: shortcutModifiers)
            do { try savedShortcut.validate(); input.switchShortcut = savedShortcut }
            catch { applyShortcut(.defaultShortcut, name: "F8") }
            session.autoReconnectEnabled = autoReconnect
            input.edgeSide = ScreenSide(rawValue: edgeSide)
            input.edgeDisplayChoice = DisplayChoice(stored: edgeDisplay)
            input.pushLevel = EdgePushLevel(rawValue: edgePush) ?? .medium
            input.translateLayouts = translateLayouts
            input.keepAwake = keepAwake
            input.restoreSharingPreference()
            attemptAutomaticConnection()
            // Show in the Dock and app switcher only while the window is open.
            NSApp.setActivationPolicy(.regular)
        }
        .onReceive(automaticTimer) { _ in attemptAutomaticConnection() }
        .onChange(of: session.adapters) { _ in attemptAutomaticConnection() }
        .onChange(of: peer) { _ in
            lookedUpPeer = ""; peerDirty = true; peerEditedAt = Date()
            if autoReconnect { session.armAutomaticConnection() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { attemptAutomaticConnection() }
        }
        .onChange(of: peerFocused) { focused in
            if !focused && peerDirty { peerDirty = false; attemptAutomaticConnection() }
        }
        .onChange(of: adapterID) { _ in if autoReconnect { session.armAutomaticConnection() } }
        .onChange(of: session.authenticated) { connected in
            if connected && autoReconnect { savePairingKey() }
        }
        .onDisappear {
            // The window closed: keep running from the menu bar only.
            NSApp.setActivationPolicy(.accessory)
        }
    }
    private func attemptAutomaticConnection() {
        guard autoReconnect else { automaticStatus = "Automatic connection is off."; return }
        guard !session.autoConnectPaused else { automaticStatus = "Automatic connection is paused. Click Connect / Start listening to resume."; return }
        guard !session.running, !session.reconnecting else { return }
        guard !peerStillBeingEdited else { automaticStatus = "Automatic connection will start when you finish entering the peer address (press Return or leave the field)."; return }
        guard let adapter else { automaticStatus = "Automatic connection is waiting for the selected Ethernet adapter."; return }
        guard Validation.ipv4(peer), peer != adapter.address else { automaticStatus = "Enter the other Mac’s Ethernet address for automatic connection."; return }
        if (try? Validation.secret(key)) != nil {
            automaticStatus = "Starting the saved Ethernet connection automatically…"
            session.start(adapter: adapter, peer: peer, secret: key, listen: listen)
        } else if lookedUpPeer != peer {
            loadPairingKey()
        } else if !loadingSavedKey {
            automaticStatus = "Automatic connection needs a pairing key. Paste the existing key or load it from Keychain. It will be saved after successful pairing."
        }
    }
    /// A partly typed address such as 172.16.1.1 (on the way to .10) is valid IPv4, so wait for
    /// Return, leaving the field, or 5 seconds without typing before connecting automatically.
    private var peerStillBeingEdited: Bool {
        guard peerDirty else { return false }
        let idle = Date().timeIntervalSince(peerEditedAt)
        return peerFocused ? idle < 5 : idle < 1
    }
    private func loadPairingKey(force: Bool = false) {
        guard Validation.ipv4(peer), !loadingSavedKey else { return }
        if !force && lookedUpPeer == peer { return }
        let target = peer
        loadingSavedKey = true; lookedUpPeer = target
        automaticStatus = "Loading saved pairing key. Approve the Keychain prompt if macOS asks."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let saved = try PairingStore.load(peer: target)
                DispatchQueue.main.async {
                    loadingSavedKey = false
                    guard peer == target else { return }
                    if let saved { key = saved; notice = "Saved pairing key loaded."; attemptAutomaticConnection() }
                    else { automaticStatus = "No pairing key is saved for this peer. Paste the existing key; it will be saved after successful pairing." }
                }
            } catch { DispatchQueue.main.async { loadingSavedKey = false; automaticStatus = error.localizedDescription } }
        }
    }
    private func savePairingKey() {
        guard Validation.ipv4(peer), (try? Validation.secret(key)) != nil, !savingKey else { return }
        let target = peer; let secret = key
        savingKey = true
        DispatchQueue.global(qos: .userInitiated).async {
            do { try PairingStore.save(secret, peer: target)
                DispatchQueue.main.async { savingKey = false; automaticStatus = "Pairing key saved. Automatic connection is ready for the next app launch." }
            } catch { DispatchQueue.main.async { savingKey = false; automaticStatus = "Could not save pairing key: \(error.localizedDescription). Reconnection works while open, but the key will be needed after reopening." } }
        }
    }
    private var versionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "Development build" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) · Build \($0)" } ?? "Version \(version)"
    }
    private var shortcutLabel: String {
        let shortcut = SwitchShortcut(keyCode: UInt16(clamping: shortcutKey), modifiers: shortcutModifiers)
        let name = shortcutKeyName.isEmpty ? ([100: "F8", 101: "F9", 109: "F10"][shortcutKey] ?? "Key \(shortcutKey)") : shortcutKeyName
        return shortcut.modifierLabel.isEmpty ? name : "\(shortcut.modifierLabel)–\(name)"
    }
    private func applyShortcut(_ shortcut: SwitchShortcut, name: String) {
        do {
            try shortcut.validate()
            shortcutKey = Int(shortcut.keyCode); shortcutModifiers = shortcut.modifiers; shortcutKeyName = name
            input.switchShortcut = shortcut
            notice = "Switching shortcut saved: \(shortcutLabel). Emergency return remains Control–Option–Escape."
        } catch { notice = error.localizedDescription }
    }
    private func requirePeer() throws {
        guard Validation.ipv4(peer) else { throw LinkError.invalid("Enter a valid Ethernet IPv4 address for the other Mac.") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { notice = error.localizedDescription }
    }
}

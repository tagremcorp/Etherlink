import AppKit
import ApplicationServices
import Carbon
import Combine
import LinkCore

/// Display layout changes refresh the cached bounds used to clamp injected pointer motion.
private let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, info in
    guard let info, !flags.contains(.beginConfigurationFlag) else { return }
    let controller = Unmanaged<InputController>.fromOpaque(info).takeUnretainedValue()
    if Thread.isMainThread { controller.refreshDisplays() }
    else { DispatchQueue.main.async { [weak controller] in controller?.refreshDisplays() } }
}

/// Core Graphics capture/injection stays on the main run loop. No keystrokes are logged.
final class InputController: ObservableObject {
    var keyboardMac: Bool { roles?.localIsKeyboard == true }
    @Published private(set) var roleConfirmed = false
    @Published private(set) var rolePromptVisible = false
    @Published private(set) var roleSummary = "Connect both Macs to choose the keyboard and mouse source."
    @Published private(set) var peerName = "Other Mac"
    @Published private(set) var localAddress = ""
    @Published private(set) var peerAddress = ""
    let localName = String((Host.current().localizedName ?? ProcessInfo.processInfo.hostName).prefix(80))
    private var roles: PairRoles?
    private var deviceID: String = {
        if CommandLine.arguments.contains("--probe") { return UUID().uuidString }
        if let saved = UserDefaults.standard.string(forKey: "deviceID"), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: "deviceID"); return id
    }()
    @Published var switchShortcut = SwitchShortcut.defaultShortcut
    var recordingShortcut = false
    @Published private(set) var status = "Enable sharing on both Macs after granting permissions."
    @Published private(set) var remote = false
    @Published private(set) var enabled = false
    @Published private(set) var sharingRequested = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var monitoringGranted = false
    @Published private(set) var secureInputActive = false
    private var paired = false
    private var pending = false
    private var controlRequest = UUID()
    private var displayBounds: [CGRect] = []
    private var receiving = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressedKeys = Set<UInt16>()
    private var pressed = PressedInputState()
    private var savedCursor = CGPoint.zero
    private var cursorHidden = false
    /// Where the local pointer waits while the other Mac is controlled.
    private var parkedCursor = CGPoint.zero
    private var permissionTimer: Timer?
    /// Keyboard Mac: the side of this Mac's desktop where the other Mac's screen sits (nil = off).
    var edgeSide: ScreenSide?
    /// Keyboard Mac: send each key's character so the other Mac can match it on its own layout.
    var translateLayouts = true
    private lazy var layout = KeyboardLayout()
    private var edgePush = EdgePush()
    private var lastSwitch: TimeInterval = 0
    /// Keyboard Mac: the display the pointer left from, so an edge return lands back there.
    private var crossDisplay: CGRect?
    /// Receiving Mac: its side facing the keyboard Mac (entry and return edge) for this control session.
    private var receiverEdge: ScreenSide?
    /// Receiving Mac: how each held source key was typed here, so its key-up matches its key-down.
    private var translatedKeys: [UInt16: (code: UInt16, shift: Bool?, option: Bool?, text: String?)] = [:]
    private var secureNotice = false
    private let marker: Int64 = 0x454C494E4B
    var send: ((WireMessage) -> Void)?

    init() {
        refreshDisplays()
        // Warping the pointer normally suppresses local mouse input for 0.25 s, which would drop
        // the first forwarded movements after switching. Parking needs no suppression.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }
    fileprivate func refreshDisplays() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { displayBounds = []; return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { displayBounds = []; return }
        displayBounds = displays.prefix(Int(count)).map(CGDisplayBounds)
    }
    /// Published values are assigned only on change so the 1-second permission poll does not redraw the window.
    private func setStatus(_ text: String) { if status != text { status = text } }

    func restoreSharingPreference() {
        if UserDefaults.standard.bool(forKey: "sharingRequested") { enable(prompt: false) }
        else { refreshPermissions() }
    }
    func enable(prompt: Bool = true) {
        sharingRequested = true
        UserDefaults.standard.set(true, forKey: "sharingRequested")
        if permissionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tryEnable() }
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if prompt { requestPermissions() }
        tryEnable()
    }
    func requestPermissions() {
        refreshPermissions()
        if !accessibilityGranted {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
        }
        if !monitoringGranted { _ = CGRequestListenEventAccess() }
    }
    private func refreshPermissions() {
        let accessibility = AXIsProcessTrusted(), monitoring = CGPreflightListenEventAccess(), secure = IsSecureEventInputEnabled()
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if monitoringGranted != monitoring { monitoringGranted = monitoring }
        if secureInputActive != secure { secureInputActive = secure }
    }
    private func tryEnable() {
        refreshPermissions()
        guard sharingRequested else { return }
        if !accessibilityGranted || !monitoringGranted {
            if enabled { removeTap() }
            let missing = [accessibilityGranted ? nil : "Accessibility", monitoringGranted ? nil : "Input Monitoring"].compactMap { $0 }.joined(separator: " and ")
            setStatus("Waiting for \(missing). Enable EtherLink in Privacy & Security. Sharing will start automatically when macOS reports access. If both toggles are already on, their entries may belong to an older build: remove EtherLink from both lists with the minus button, add /Applications/EtherLink.app with the plus button, then reopen it.")
            return
        }
        // Secure input only matters on the keyboard Mac: macOS then hides its keystrokes from the
        // event tap, so they would go to the local app instead of the other Mac. The receiving Mac
        // can still type into its own password fields, because posted events are not blocked.
        if secureInputActive && keyboardMac {
            if remote || pending { returnLocal() }
            secureNotice = true
            setStatus("Secure input is on in \(SystemState.secureInputOwner() ?? "another app") on this Mac, so macOS hides its keystrokes. Control stays here until it ends: leave the password field, or turn off Secure Keyboard Entry in Terminal’s menu.")
        } else if secureNotice {
            secureNotice = false
            setStatus("Secure input ended. Ready to switch control.")
        }
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<InputController>.fromOpaque(context).takeUnretainedValue().capture(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "Could not enable input capture. Check Accessibility and Input Monitoring permissions, then reopen EtherLink."
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        enabled = true
        status = roleConfirmed ? (keyboardMac ? "Ready. Your switching shortcut changes control; Control–Option–Escape returns here." : "Ready to receive input from the Keyboard Mac.") : "Permissions ready. Choose the keyboard and mouse source on either Mac."
    }

    private func removeTap() {
        returnLocal()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; enabled = false
    }
    func disable() {
        sharingRequested = false
        UserDefaults.standard.set(false, forKey: "sharingRequested")
        permissionTimer?.invalidate(); permissionTimer = nil
        removeTap()
        status = "Sharing disabled. Keyboard and mouse control this Mac."
    }
    /// Restore input on app exit without forgetting the user's enable choice.
    func terminate() {
        permissionTimer?.invalidate(); permissionTimer = nil
        removeTap()
        UserDefaults.standard.set(sharingRequested, forKey: "sharingRequested")
    }
    func connected(coordinator: Bool, localAddress: String, peerAddress: String) {
        paired = true
        self.localAddress = localAddress; self.peerAddress = peerAddress
        roles = PairRoles(localID: deviceID, localName: localName, coordinator: coordinator)
        syncRoleUI(); send?(roles!.hello)
    }
    func disconnected() {
        paired = false; pending = false
        restoreCursor(); releaseInjected(); receiving = false
        roles = nil; syncRoleUI()
        if enabled { status = "Connection lost. Keyboard and mouse control this Mac." }
    }
    private func pauseForRoleSetup() {
        pending = false; restoreCursor(); releaseInjected(); receiving = false
    }
    func requestRoleSetup() {
        guard var roles else { status = "Pair the Macs before choosing the keyboard source."; return }
        returnLocal(); pauseForRoleSetup()
        let messages = roles.requestSetup(); self.roles = roles; syncRoleUI()
        messages.forEach { send?($0) }
    }
    func chooseKeyboardSource(here: Bool) {
        guard var roles else { return }
        let messages = roles.choose(local: here); self.roles = roles; syncRoleUI()
        messages.forEach { send?($0) }
    }
    func cancelRoleSetup() {
        guard var roles else { return }
        let messages = roles.cancel(); self.roles = roles; syncRoleUI()
        messages.forEach { send?($0) }
    }
    private func syncRoleUI() {
        let wasPrompt = rolePromptVisible
        roleConfirmed = roles?.isConfirmed == true
        rolePromptVisible = roles?.needsChoice == true
        peerName = roles?.peerName ?? "Other Mac"
        if roleConfirmed {
            roleSummary = keyboardMac ? "Keyboard and mouse source: this Mac (\(localName)). \(peerName) receives forwarded input." : "Keyboard and mouse source: \(peerName). This Mac receives forwarded input."
            if enabled { status = keyboardMac ? "Ready to switch control." : "Ready to receive input." }
            if !CommandLine.arguments.contains("--probe"), let peerID = roles?.peerID, let sourceID = roles?.confirmedSourceID {
                var saved = UserDefaults.standard.dictionary(forKey: "confirmedKeyboardSources") as? [String:String] ?? [:]
                saved[peerID] = sourceID; UserDefaults.standard.set(saved, forKey: "confirmedKeyboardSources")
            }
        } else if paired {
            roleSummary = rolePromptVisible ? "Choose which Mac receives input through your keyboard/mouse or monitor USB hub. Answer on either screen." : "No confirmed keyboard source. Choose the source on either Mac to continue."
            if enabled { status = "Sharing is paused until the keyboard and mouse source is confirmed." }
        } else { roleSummary = "Connect both Macs to choose the keyboard and mouse source." }
        if rolePromptVisible && !wasPrompt, let app = NSApp {
            app.activate(ignoringOtherApps: true)
            for window in app.windows where window.canBecomeMain { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
        }
    }
    func receive(_ message: WireMessage) throws {
        if message.kind.isRoleMessage {
            guard var roles else { throw LinkError.invalid("Role setup arrived before connection.") }
            if [.roleSetupRequest, .rolePrompt, .roleAssignment, .roleCancel].contains(message.kind) { pauseForRoleSetup() }
            let saved = UserDefaults.standard.dictionary(forKey: "confirmedKeyboardSources") as? [String:String] ?? [:]
            let outgoing = try roles.receive(message, savedSourceID: saved[message.deviceID ?? ""])
            self.roles = roles; syncRoleUI(); outgoing.forEach { send?($0) }
            return
        }
        switch message.kind {
        case .takeControl:
            guard roleConfirmed, !keyboardMac, enabled, AXIsProcessTrusted() else {
                var denied = WireMessage(.denied)
                denied.reason = "\(localName) is not ready. Click Enable sharing there and grant Accessibility and Input Monitoring."
                send?(denied); return
            }
            releaseInjected(); receiving = true
            translatedKeys.removeAll(); edgePush.reset(); lastSwitch = ProcessInfo.processInfo.systemUptime
            receiverEdge = message.edge.flatMap(ScreenSide.init(rawValue:))?.opposite
            if let side = receiverEdge, let position = message.position,
               let display = EdgeGeometry.extremeDisplay(side: side, displays: displayBounds) {
                moveInjectedPointer(to: EdgeGeometry.point(on: display, side: side, position: position))
            }
            status = "Receiving keyboard and mouse. Control–Option–Escape returns control to the Keyboard Mac."
            var granted = WireMessage(.granted)
            if SystemState.screenLocked {
                granted.reason = "\(localName) is locked. macOS may ignore forwarded typing at the lock screen; unlock it with its own keyboard, Touch ID or Apple Watch."
            }
            send?(granted)
        case .granted:
            guard roleConfirmed, keyboardMac, pending, enabled else { send?(.init(.releaseControl)); return }
            pending = false; remote = true; lastSwitch = ProcessInfo.processInfo.systemUptime
            savedCursor = CGEvent(source: nil)?.location ?? .zero
            releaseLocalModifiers()
            parkCursor()
            status = message.reason ?? "Controlling \(peerName). Control–Option–Escape always returns here."
        case .denied:
            pending = false
            status = message.reason ?? "Other Mac is not ready. Click Enable sharing there and grant Accessibility and Input Monitoring."
        case .releaseControl:
            guard !keyboardMac else { return }
            releaseInjected(); receiving = false; status = "Ready to receive input."
        case .returnControl:
            guard keyboardMac else { return }
            // An edge return puts the pointer back on the edge it crossed, at the matching position.
            if remote, let position = message.position, let side = edgeSide,
               let display = crossDisplay ?? EdgeGeometry.extremeDisplay(side: side, displays: displayBounds) {
                savedCursor = EdgeGeometry.point(on: display, side: side, position: position)
            }
            returnLocal()
        case .input:
            guard roleConfirmed, !keyboardMac, receiving, enabled, let input = message.input else { return }
            try inject(input)
        default: break
        }
    }
    func toggle(edgePosition: Double? = nil) {
        if remote || pending { returnLocal(); return }
        guard roleConfirmed, keyboardMac, paired, enabled else {
            status = "Pair both Macs, choose the keyboard source on either screen, and enable sharing on both before switching."; return
        }
        guard !IsSecureEventInputEnabled() else {
            status = "Secure input is on in \(SystemState.secureInputOwner() ?? "another app") on this Mac, so macOS hides its keystrokes. Leave the password field, or turn off Secure Keyboard Entry in Terminal’s menu, then switch."
            return
        }
        if edgePosition == nil { crossDisplay = nil }
        let request = UUID(); controlRequest = request
        pending = true; status = "Requesting control of \(peerName)…"
        var take = WireMessage(.takeControl)
        take.edge = edgeSide?.rawValue   // also lets the other Mac return control through its edge
        take.position = edgePosition
        send?(take)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            // Only the request that armed this timer may time out; a later request has its own.
            guard let self, self.pending, self.controlRequest == request else { return }
            self.pending = false; self.send?(.init(.releaseControl))
            self.status = "The Other Mac did not accept control. Check Enable sharing and permissions there."
        }
    }
    func returnLocal(edgePosition: Double? = nil) {
        pending = false; edgePush.reset(); lastSwitch = ProcessInfo.processInfo.systemUptime
        if keyboardMac { if paired { send?(.init(.releaseControl)) }; restoreCursor() }
        else {
            releaseInjected(); receiving = false; receiverEdge = nil
            var message = WireMessage(.returnControl); message.position = edgePosition
            if paired { send?(message) }
        }
        if enabled { status = keyboardMac ? "Keyboard and mouse control this Mac." : "Ready to receive input." }
    }
    /// Moves the local pointer to the bottom-right corner of its display and holds it there.
    /// A background app cannot reliably hide the pointer, and macOS can re-associate mouse and
    /// pointer (for example after Mission Control), so the hold is re-asserted on each mouse event.
    private func parkCursor() {
        let display = displayBounds.first { $0.contains(savedCursor) } ?? CGDisplayBounds(CGMainDisplayID())
        parkedCursor = CGPoint(x: display.maxX - 2, y: display.maxY - 2)
        CGWarpMouseCursorPosition(parkedCursor)
        CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden { CGDisplayHideCursor(CGMainDisplayID()); cursorHidden = true }
    }
    private func holdParkedCursor(_ event: CGEvent) {
        CGAssociateMouseAndMouseCursorPosition(0)
        let at = event.location
        if abs(at.x - parkedCursor.x) > 1 || abs(at.y - parkedCursor.y) > 1 { CGWarpMouseCursorPosition(parkedCursor) }
    }
    private func restoreCursor() {
        if remote {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(savedCursor)
        }
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()); cursorHidden = false }
        remote = false
    }
    private func capture(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            returnLocal()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            status = "Input capture was interrupted. Control returned locally."
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        let key = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        // Recording is scoped to the settings window, with local control restored first.
        if recordingShortcut && !remote { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        let modifiers = (flags.contains(.maskControl) ? SwitchShortcut.control : 0)
            | (flags.contains(.maskAlternate) ? SwitchShortcut.option : 0)
            | (flags.contains(.maskShift) ? SwitchShortcut.shift : 0)
            | (flags.contains(.maskCommand) ? SwitchShortcut.command : 0)
        let emergency = SwitchShortcut.emergency.matches(keyCode: key, modifiers: modifiers)
        let switching = keyboardMac && switchShortcut.matches(keyCode: key, modifiers: modifiers)
        if type == .keyDown, emergency || switching {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if emergency { returnLocal() } else { toggle() }
            }
            suppressedKeys.insert(key); return nil
        }
        if type == .keyUp, suppressedKeys.remove(key) != nil { return nil }
        if type == .mouseMoved, keyboardMac, !remote, !pending { checkEdgeCrossing(event) }
        guard keyboardMac, remote else { return Unmanaged.passUnretained(event) }
        var p = InputPacket(kind: .move)
        p.key = key; p.flags = event.flags.rawValue
        p.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        p.button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        p.clicks = min(4, max(0, Int(event.getIntegerValueField(.mouseEventClickState))))
        switch type {
        case .keyDown: p.kind = .keyDown
        case .keyUp: p.kind = .keyUp
        case .flagsChanged: p.kind = .flags
        case .mouseMoved: p.kind = .move
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: p.kind = .drag
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: p.kind = .buttonDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: p.kind = .buttonUp
        case .scrollWheel:
            p.kind = .scroll; p.precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            p.dx = event.getDoubleValueField(p.precise ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)
            p.dy = event.getDoubleValueField(p.precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
            p.phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            p.momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        default: return Unmanaged.passUnretained(event)
        }
        if [.move, .drag, .buttonDown, .buttonUp].contains(p.kind) { holdParkedCursor(event) }
        if p.kind == .move || p.kind == .drag {
            p.dx = event.getDoubleValueField(.mouseEventDeltaX); p.dy = event.getDoubleValueField(.mouseEventDeltaY)
        }
        if p.kind != .keyDown && p.kind != .keyUp && p.kind != .flags { p.key = 0 }
        if translateLayouts, p.kind == .keyDown || p.kind == .keyUp,
           let text = layout.text(for: key, shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate),
                                  capsLock: flags.contains(.maskAlphaShift)),
           KeyLayoutMap.isPrintable(text) {
            p.text = text
        }
        if p.isValid { send?(.init(.input, input: p)) }
        return nil
    }
    /// Keyboard Mac: a deliberate push against the configured outer edge switches control.
    /// Only plain movement counts; a drag in progress never crosses.
    private func checkEdgeCrossing(_ event: CGEvent) {
        guard let side = edgeSide, roleConfirmed, paired, enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSwitch > 0.5,
              let display = EdgeGeometry.outerEdgeDisplay(at: event.location, side: side, displays: displayBounds) else {
            edgePush.reset(); return
        }
        let pressure = side.pressure(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        guard edgePush.push(pressure, now: now) else { return }
        crossDisplay = display
        toggle(edgePosition: EdgeGeometry.position(of: event.location, on: display, side: side))
    }
    /// Receiving Mac: moves its pointer, with a move event so apps update hover state.
    private func moveInjectedPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        post(event)
    }
    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
    private func releaseLocalModifiers() {
        for key: CGKeyCode in [54, 55, 56, 60, 58, 61, 59, 62] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
            event?.flags = []; post(event)
        }
    }
    private func inject(_ p: InputPacket) throws {
        guard p.isValid else { throw LinkError.invalid("Invalid input packet.") }
        pressed.record(p)
        let location = CGEvent(source: nil)?.location ?? .zero
        var event: CGEvent?
        switch p.kind {
        case .keyDown, .keyUp:
            let typed = translatedKey(p)
            event = CGEvent(keyboardEventSource: nil, virtualKey: typed.code, keyDown: p.kind == .keyDown)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: p.autorepeat ? 1 : 0)
            var flags = CGEventFlags(rawValue: p.flags)
            if let shift = typed.shift { if shift { flags.insert(.maskShift) } else { flags.remove(.maskShift) } }
            if let option = typed.option { if option { flags.insert(.maskAlternate) } else { flags.remove(.maskAlternate) } }
            event?.flags = flags
            if let text = typed.text {
                let units = Array(text.utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            post(event)
            return
        case .flags:
            event = CGEvent(keyboardEventSource: nil, virtualKey: p.key, keyDown: false)
            event?.type = .flagsChanged
        case .move, .drag:
            let target = clamped(CGPoint(x: location.x + p.dx, y: location.y + p.dy))
            let type: CGEventType = p.kind == .move ? .mouseMoved : (p.button == 0 ? .leftMouseDragged : (p.button == 1 ? .rightMouseDragged : .otherMouseDragged))
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: CGMouseButton(rawValue: UInt32(p.button)) ?? .center)
            event?.setDoubleValueField(.mouseEventDeltaX, value: target.x - location.x)
            event?.setDoubleValueField(.mouseEventDeltaY, value: target.y - location.y)
            if p.kind == .move, checkEdgeReturn(target: target, packet: p) {
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(p.button))
                event?.flags = CGEventFlags(rawValue: p.flags)
                post(event)
                return
            }
        case .buttonDown, .buttonUp:
            let down = p.kind == .buttonDown
            let type: CGEventType = p.button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : (p.button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp))
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: CGMouseButton(rawValue: UInt32(p.button)) ?? .center)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(p.clicks))
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: nil, units: p.precise ? .pixel : .line, wheelCount: 2, wheel1: Int32(p.dy), wheel2: Int32(p.dx), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: p.phase)
            event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: p.momentum)
            if p.precise {
                event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: p.dy)
                event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: p.dx)
            }
        }
        if [.move, .drag, .buttonDown, .buttonUp].contains(p.kind) {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(p.button))
        }
        event?.flags = CGEventFlags(rawValue: p.flags)
        post(event)
    }
    /// Receiving Mac: how to type a forwarded key here. With the source's character available, the
    /// key that types that character on this Mac's layout is used (keeping Command/Control, so
    /// shortcuts follow the character too). A character this layout cannot type at all is posted as
    /// text on the original key, unless Command or Control is held. Key-ups reuse the key-down choice.
    private func translatedKey(_ p: InputPacket) -> (code: UInt16, shift: Bool?, option: Bool?, text: String?) {
        if p.kind == .keyUp, let previous = translatedKeys.removeValue(forKey: p.key) { return previous }
        guard p.kind == .keyDown, let text = p.text else { return (p.key, nil, nil, nil) }
        let flags = CGEventFlags(rawValue: p.flags)
        let result: (code: UInt16, shift: Bool?, option: Bool?, text: String?)
        if let chord = layout.map.resolve(text, original: p.key, shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate)) {
            result = (chord.keyCode, chord.shift, chord.option, nil)
        } else if !flags.contains(.maskCommand) && !flags.contains(.maskControl) {
            result = (p.key, nil, nil, text)
        } else {
            result = (p.key, nil, nil, nil)
        }
        translatedKeys[p.key] = result
        return result
    }
    /// Receiving Mac: a deliberate push against the edge facing the keyboard Mac returns control.
    /// Returns true when control was handed back.
    private func checkEdgeReturn(target: CGPoint, packet p: InputPacket) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard receiving, let side = receiverEdge, now - lastSwitch > 0.5,
              let display = EdgeGeometry.outerEdgeDisplay(at: target, side: side, displays: displayBounds) else {
            edgePush.reset(); return false
        }
        guard edgePush.push(side.pressure(dx: p.dx, dy: p.dy), now: now) else { return false }
        let position = EdgeGeometry.position(of: target, on: display, side: side)
        DispatchQueue.main.async { [weak self] in
            self?.returnLocal(edgePosition: position)
            self?.status = "Control returned to the Keyboard Mac through the screen edge."
        }
        return true
    }
    private func releaseInjected() {
        for release in pressed.drain() { try? inject(release) }
    }
    private func clamped(_ point: CGPoint) -> CGPoint {
        var closest = point; var distance = Double.infinity
        for bounds in displayBounds {
            if bounds.contains(point) { return point }
            let candidate = CGPoint(x: min(bounds.maxX - 1, max(bounds.minX, point.x)), y: min(bounds.maxY - 1, max(bounds.minY, point.y)))
            let d = pow(candidate.x - point.x, 2) + pow(candidate.y - point.y, 2)
            if d < distance { closest = candidate; distance = d }
        }
        return closest
    }
}

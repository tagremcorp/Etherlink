import Foundation
import Network
import Security
import Combine
import AppKit
import LinkCore

/// Published setup state is serialized on the main queue; ConnectionIO owns independent socket traffic.
final class LinkSession: ObservableObject {
    @Published private(set) var status = "Disconnected"
    @Published private(set) var pathDescription = "No established connection"
    @Published private(set) var received: UInt64 = 0
    @Published private(set) var running = false
    @Published private(set) var reconnecting = false
    @Published private(set) var authenticated = false
    @Published private(set) var autoConnectPaused = false
    @Published private(set) var adapters: [Adapter] = []
    @Published private(set) var events: [String] = []
    private let monitor = NWPathMonitor()
    private(set) var discoveryStatus = "Waiting for Network.framework"
    private var discoveryTimer: DispatchSourceTimer?
    private var resolver: NWConnection?
    private var listener: NWListener?
    private var connectionIO: ConnectionIO?
    private var timer: DispatchSourceTimer?
    private var selected: Adapter?
    private var peer = ""
    private var started: TimeInterval = 0
    private var startupDeadline: TimeInterval = 0
    private var listenerReady = false
    private var lastPathRetry: TimeInterval = 0
    private var terminationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var reconnectToken = UUID()
    private var reconnectIntent: (adapterID: String, peer: String, secret: String, listen: Bool)?
    var autoReconnectEnabled = true
    lazy var input: InputController = {
        let input = InputController()
        input.send = { [weak self] message in self?.sendWire(message) }
        return input
    }()
    private var generation = UUID()
    private let port = NWEndpoint.Port(rawValue: 49277)!
    var onStatus: ((String) -> Void)?
    var onHeartbeat: ((UInt64) -> Void)?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.input.terminate(); self?.disconnect()
        }
        // Lives here rather than in the window so it still applies while the window is closed.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running || self.reconnecting else { return }
            self.stop("Mac is sleeping. Reconnecting after wake.")
        }
        monitor.pathUpdateHandler = { [weak self] path in self?.refreshAdapters(path) }
        monitor.start(queue: .main)
        let discoveryTimer = DispatchSource.makeTimerSource(queue: .main)
        discoveryTimer.schedule(deadline: .now() + 2, repeating: 2)
        discoveryTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshAdapters(self.monitor.currentPath)
        }
        self.discoveryTimer = discoveryTimer
        discoveryTimer.resume()
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        monitor.cancel(); discoveryTimer?.cancel(); resolver?.cancel()
        timer?.cancel(); connectionIO?.cancel(); listener?.cancel()
    }
    private func refreshAdapters(_ path: NWPath) {
        let discovered = Adapter.discover(path)
        if discovered != adapters { adapters = discovered }
        discoveryStatus = "Path: \(path.status); interfaces: \(path.availableInterfaces.map { "\($0.name):\($0.type)" }); addresses: \(Adapter.addresses())"
        if let selected, running, !discovered.contains(where: { $0.id == selected.id }) {
            stop("Selected Ethernet adapter or address disappeared. \(retryHint)")
        }
    }

    private var retryHint: String {
        autoReconnectEnabled && reconnectIntent != nil
            ? "Reconnecting automatically when it returns."
            : "Connect again when it returns."
    }

    private func report(_ message: String) {
        status = message
        events.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if events.count > 30 { events.removeFirst() }
        onStatus?(message)
    }

    func start(adapter: Adapter, peer: String, secret: String, listen: Bool, deadline: TimeInterval? = nil) {
        stop(nil, allowReconnect: false)
        reconnectToken = UUID(); reconnecting = false
        reconnectIntent = (adapter.id, peer, secret, listen)
        autoConnectPaused = false
        startupDeadline = deadline ?? (ProcessInfo.processInfo.systemUptime + 120)
        // Only a missing adapter address can fix itself (cable replugged); other start errors cannot.
        var retryable = false
        do {
            guard Validation.ipv4(peer) else { throw LinkError.invalid("Enter the other Mac’s Ethernet IPv4 address.") }
            guard Adapter.addresses()[adapter.name]?.contains(adapter.address) == true else {
                retryable = true
                throw LinkError.invalid("Selected adapter no longer has that address. \(retryHint)")
            }
            let key = try Validation.secret(secret)
            guard let interface = adapter.interface else {
                resolve(adapter: adapter, peer: peer, secret: secret, listen: listen)
                return
            }
            selected = adapter; self.peer = peer
            let tls = NWProtocolTLS.Options()
            // Platform TLS PSK authenticates possession of the manually exchanged random key.
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data("EtherLink-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
            sec_protocol_options_set_tls_tickets_enabled(options, false)
            sec_protocol_options_set_tls_resumption_enabled(options, false)
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            parameters.requiredInterface = interface
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address(adapter.address)!), port: listen ? port : .any)
            parameters.includePeerToPeer = false
            parameters.multipathServiceType = .disabled
            parameters.preferNoProxies = true
            running = true; started = ProcessInfo.processInfo.systemUptime
            let token = generation
            if listen {
                let listener: NWListener
                do { listener = try NWListener(using: parameters) }
                catch { throw LinkError.invalid("Could not listen on \(adapter.address):49277 (\(error)). Another copy of EtherLink may already be running; quit it, then click Start listening.") }
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .ready:
                        self.listenerReady = true
                        self.report("Listening on \(adapter.label):49277 — ready for the other Mac to connect")
                    case .failed(.posix(.EADDRINUSE)):
                        // Retrying cannot help while another process owns the port.
                        self.reconnectIntent = nil
                        self.stop("Port 49277 on \(adapter.address) is already in use. Another copy of EtherLink may be running; quit it, then click Start listening.", allowReconnect: false)
                    case .failed(let error): self.stop("Listener failed: \(error)")
                    case .waiting:
                        self.report("Waiting to start listening. If macOS asks for network access, choose Allow. Listening will resume automatically; no second click is needed.")
                    default: break
                    }
                    }
                }
                // Accept/start TLS off the UI queue so a local permission dialog cannot stall it.
                var accepted = false // accessed only by the listener's serial transport queue
                listener.newConnectionHandler = { [weak self] incoming in
                    guard !accepted, case .hostPort(let host, _) = incoming.endpoint, "\(host)" == peer else { incoming.cancel(); return }
                    accepted = true
                    guard let self else { incoming.cancel(); return }
                    let io = self.makeIO(incoming, adapter: adapter, peer: peer, token: token, coordinator: true, deadline: ProcessInfo.processInfo.systemUptime + 15)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { io.cancel(); return }
                        self.connectionIO = io
                    }
                    io.start()
                }
                listener.start(queue: ConnectionIO.queue)
                report("Starting Ethernet listener…")
            } else {
                report("Connecting to \(peer) over \(adapter.name)…")
                attach(NWConnection(host: .ipv4(IPv4Address(peer)!), port: port, using: parameters), token: token)
            }
            scheduleTimer(token: token)
        } catch {
            if !retryable { reconnectIntent = nil }
            stop(error.localizedDescription, allowReconnect: retryable)
        }
    }

    /// Resolve an Ethernet-only path to the actual peer, rather than the Internet.
    /// UDP is used only to obtain NWInterface metadata; no application data is sent.
    private func resolve(adapter: Adapter, peer: String, secret: String, listen: Bool) {
        selected = adapter; running = true
        report("Resolving \(peer) through \(adapter.label)…")
        let token = generation
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wiredEthernet
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address(adapter.address)!), port: .any)
        parameters.preferNoProxies = true
        let resolver = NWConnection(host: .ipv4(IPv4Address(peer)!), port: 9, using: parameters)
        self.resolver = resolver
        resolver.stateUpdateHandler = { [weak self, weak resolver] state in
            guard let self, let resolver, self.generation == token else { return }
            switch state {
            case .ready:
                guard let interface = resolver.currentPath?.availableInterfaces.first(where: {
                    $0.name == adapter.name && $0.type == .wiredEthernet
                }) else { self.stop("Could not verify the selected Ethernet interface."); return }
                self.start(adapter: Adapter(interface: interface, address: adapter.address), peer: peer, secret: secret, listen: listen, deadline: self.startupDeadline)
            case .failed(let error):
                self.stop(self.networkFailure(error, path: resolver.currentPath, context: "Selected Ethernet path unavailable"))
            case .waiting(let error):
                self.report(self.waitingMessage(error, path: resolver.currentPath))
            default: break
            }
        }
        resolver.start(queue: .main)
        scheduleTimer(token: token)
    }

    private func scheduleTimer(token: UUID) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick(token: token) }
        self.timer = timer; timer.resume()
    }

    private func waitingMessage(_ error: NWError, path: NWPath?) -> String {
        if path?.status == .unsatisfied && path?.unsatisfiedReason == .localNetworkDenied {
            return "Waiting for Local Network access. Choose Allow in the macOS prompt; setup will continue automatically. If you denied access, enable EtherLink in Privacy & Security → Local Network."
        }
        if case .posix(.ECONNREFUSED) = error {
            return "Waiting for the other Mac to listen. Start listening there and allow network access if prompted; this Mac will retry automatically."
        }
        return "Waiting for Ethernet or network permission. Choose Allow if prompted; setup will continue automatically. Cancel to stop. (\(error))"
    }

    private func attach(_ c: NWConnection, token: UUID) {
        guard let selected else { c.cancel(); return }
        let io = makeIO(c, adapter: selected, peer: peer, token: token, coordinator: false, deadline: startupDeadline)
        connectionIO = io; io.start()
    }
    private func makeIO(_ c: NWConnection, adapter: Adapter, peer: String, token: UUID, coordinator: Bool, deadline: TimeInterval) -> ConnectionIO {
        let io = ConnectionIO(c, adapter: adapter, peer: peer, deadline: deadline)
        io.onReady = { [weak self] description in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.authenticated = true; self.pathDescription = description
                self.input.connected(coordinator: coordinator, localAddress: adapter.address, peerAddress: peer); self.report("Paired · encrypted Ethernet connection")
            }
        }
        io.onWaiting = { [weak self] message in
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.report(message) }
        }
        io.onMessages = { [weak self] messages, count in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.received = count; self.onHeartbeat?(count)
                do { for message in messages { try self.input.receive(message) } }
                catch { self.stop("Protocol rejected: \(error.localizedDescription)", allowReconnect: false) }
            }
        }
        io.onStopped = { [weak self] message, retry in
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.stop(message, allowReconnect: retry) }
        }
        return io
    }

    private func networkFailure(_ error: NWError, path: NWPath?, context: String) -> String {
        if let path, path.status == .unsatisfied, path.unsatisfiedReason == .localNetworkDenied {
            return "macOS blocked Local Network access for EtherLink. Enable EtherLink in System Settings → Privacy & Security → Local Network, then quit and reopen the app."
        }
        var details = "\(context): \(error)."
        if let path, path.status == .unsatisfied {
            details += " Path reason: \(path.unsatisfiedReason)."
        }
        if case .posix(.ENETDOWN) = error {
            details += " If the peer responds to ping, check EtherLink’s Local Network permission in System Settings → Privacy & Security."
        }
        return details
    }

    private func tick(token: UUID) {
        guard token == generation, running, let selected else { return }
        guard Adapter.addresses()[selected.name]?.contains(selected.address) == true else {
            stop("Selected Ethernet address changed. \(retryHint)"); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Connected traffic and the watchdog run in ConnectionIO, independently of AppKit.
        if connectionIO != nil { return }
        if resolver != nil || (listener != nil && !listenerReady) {
            guard now < startupDeadline else { stop("Setup timed out. Retrying automatically when enabled."); return }
        }
        if now - lastPathRetry >= 5, let resolver, case .waiting = resolver.state { lastPathRetry = now; resolver.restart() }
    }
    private func sendWire(_ message: WireMessage) { connectionIO?.send(message) }
    func stop(_ reason: String? = "Disconnected", allowReconnect: Bool = true) {
        generation = UUID()
        input.disconnected()
        resolver?.cancel(); resolver = nil
        timer?.cancel(); timer = nil
        connectionIO?.cancel(); connectionIO = nil
        listener?.cancel(); listener = nil
        running = false; authenticated = false; selected = nil; listenerReady = false
        received = 0
        pathDescription = "No established connection"
        if let reason { report(reason) }
        if allowReconnect { scheduleReconnect() }
        else if reason != nil { autoConnectPaused = true }
    }
    func armAutomaticConnection() { autoConnectPaused = false }
    func disconnect() {
        reconnectToken = UUID(); reconnectIntent = nil; reconnecting = false; autoConnectPaused = true
        stop("Disconnected. Automatic reconnection is stopped.", allowReconnect: false)
    }
    func scheduleReconnect() {
        reconnectToken = UUID(); reconnecting = false
        guard autoReconnectEnabled, !running, reconnectIntent != nil else { return }
        reconnecting = true
        let token = reconnectToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, token == self.reconnectToken, self.autoReconnectEnabled,
                  !self.running, let intent = self.reconnectIntent else { return }
            guard let adapter = self.adapters.first(where: { $0.id == intent.adapterID }) else {
                self.report("Waiting for the selected Ethernet adapter. Retrying every five seconds.")
                self.scheduleReconnect(); return
            }
            self.start(adapter: adapter, peer: intent.peer, secret: intent.secret, listen: intent.listen)
        }
    }
}

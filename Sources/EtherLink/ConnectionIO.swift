import Foundation
import Network
import LinkCore

/// All socket traffic, parsing, heartbeats and watchdogs are serialized independently of AppKit.
final class ConnectionIO {
    static let queue = DispatchQueue(label: "local.EtherLink.transport", qos: .userInteractive)
    private let connection: NWConnection
    private let local: String
    private let peer: String
    private let interfaceIndex: Int
    private let interfaceName: String
    private var decoder = WireDecoder()
    private let encoder = JSONEncoder()
    private var health = LinkHealth(now: 0)
    private var timer: DispatchSourceTimer?
    private var outgoing: [WireMessage] = []
    private var sending = false
    private var ready = false
    private var stopped = false
    private var sequence: UInt64 = 0
    private var received: UInt64 = 0
    private var started = ProcessInfo.processInfo.systemUptime
    private var deadline: TimeInterval
    private var lastRetry: TimeInterval = 0
    var onReady: ((String) -> Void)?
    var onWaiting: ((String) -> Void)?
    var onMessages: (([WireMessage], UInt64) -> Void)?
    var onStopped: ((String, Bool) -> Void)?

    init(_ connection: NWConnection, adapter: Adapter, peer: String, deadline: TimeInterval) {
        self.connection = connection; local = adapter.address; self.peer = peer
        interfaceIndex = adapter.index; interfaceName = adapter.name; self.deadline = deadline
    }
    func start() {
        Self.queue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.pathUpdateHandler = { [weak self] path in
                guard let self, self.ready, !self.stopped else { return }
                if self.verified(path) == nil { self.fail("Ethernet path changed. Control returned locally.") }
            }
            connection.viabilityUpdateHandler = { [weak self] viable in
                guard let self, self.ready, !viable else { return }
                self.fail("Ethernet connection lost. Control returned locally.")
            }
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
            connection.start(queue: Self.queue)
        }
    }
    func send(_ message: WireMessage) { Self.queue.async { [weak self] in self?.enqueue(message) } }
    func cancel() { Self.queue.async { [self] in shutdown() } }
    private func shutdown() {
        stopped = true; ready = false
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil; connection.viabilityUpdateHandler = nil
        connection.cancel(); outgoing.removeAll()
    }
    private func fail(_ message: String, retry: Bool = true) {
        guard !stopped else { return }
        shutdown(); onStopped?(message, retry)
    }
    private func stateChanged(_ state: NWConnection.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let description = verified(connection.currentPath) else { fail("Rejected unverified Ethernet path.", retry: false); return }
            ready = true; health = LinkHealth(now: ProcessInfo.processInfo.systemUptime)
            receive(); enqueue(.init(.heartbeat)); onReady?(description)
        case .preparing: started = ProcessInfo.processInfo.systemUptime
        case .waiting(let error):
            if case .tls = error { fail("Pairing failed: \(error). Check that both Macs use the same key.", retry: false) }
            else if ready { fail("Ethernet unavailable: \(error)") }
            else {
                let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                onWaiting?(denied ? "Waiting for Local Network access. Choose Allow; connection will continue automatically." : "Waiting for the other Mac to listen. Retrying over Ethernet every five seconds. (\(error))")
            }
        case .failed(let error):
            if case .tls = error { fail("Pairing failed: \(error). Check the pairing key.", retry: false) }
            else { fail("Connection failed: \(error)") }
        case .cancelled: fail("Connection closed")
        default: break
        }
    }
    private func verified(_ path: NWPath?) -> String? {
        guard let path, path.status == .satisfied, path.usesInterfaceType(.wiredEthernet), !path.usesInterfaceType(.wifi),
              path.availableInterfaces.contains(where: { $0.index == interfaceIndex }),
              case .hostPort(let source, _) = path.localEndpoint,
              case .hostPort(let destination, _) = path.remoteEndpoint,
              "\(source)" == local, "\(destination)" == peer else { return nil }
        return "Interface: \(interfaceName) (index \(interfaceIndex))\nLocal: \(path.localEndpoint!)\nRemote: \(path.remoteEndpoint!)\nTLS 1.2 · PSK · AES-128-GCM"
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if ready {
            guard !health.expired(now: now) else { fail("Heartbeat timeout: Ethernet peer stopped responding."); return }
            guard Adapter.addresses()[interfaceName]?.contains(local) == true else { fail("Selected Ethernet address disappeared."); return }
            enqueue(.init(.heartbeat))
        } else {
            guard now < deadline else { fail("Connection setup timed out. Retrying automatically when enabled."); return }
            if case .waiting = connection.state {
                if now - lastRetry >= 5 { lastRetry = now; connection.restart() }
            } else if now - started > 15 { fail("TLS handshake timed out. Check the peer’s listener and firewall.") }
        }
    }
    private func enqueue(_ message: WireMessage) {
        guard ready, !stopped else { return }
        // Only unsent messages are in `outgoing`; the in-flight one was already removed by flush().
        if message.kind == .input, let incoming = message.input,
           let tail = outgoing.last, tail.kind == .input, let merged = tail.input?.merged(with: incoming) {
            outgoing[outgoing.count - 1] = .init(.input, input: merged)
        } else {
            guard outgoing.count < 256 else { fail("Input queue fell behind. Control returned locally."); return }
            outgoing.append(message)
        }
        flush()
    }
    private func flush() {
        guard !sending, !outgoing.isEmpty, !stopped else { return }
        var message = outgoing.removeFirst(); sequence += 1; message.sequence = sequence
        do {
            var data = try encoder.encode(message); data.append(10); sending = true
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                self.sending = false
                if let error { self.fail("Send failed: \(error)") } else { self.flush() }
            })
        } catch { fail("Could not encode protocol message.", retry: false) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            do {
                if let data {
                    let messages = try self.decoder.append(data)
                    if !messages.isEmpty {
                        self.health.received(now: ProcessInfo.processInfo.systemUptime)
                        // A heartbeat carrying display, activity or lock information is a message for
                        // the input controller. Only plain heartbeats count as link heartbeats.
                        let plain = messages.filter { $0.kind == .heartbeat && $0.displays == nil && $0.active == nil && $0.locked == nil }.count
                        self.received += UInt64(plain)
                        self.onMessages?(messages.filter { $0.kind != .heartbeat || $0.displays != nil || $0.active != nil || $0.locked != nil }, self.received)
                    }
                }
                if complete || error != nil { self.fail("Peer disconnected\(error.map { ": \($0)" } ?? "")"); return }
                self.receive()
            } catch { self.fail("Protocol rejected: \(error.localizedDescription)", retry: false) }
        }
    }
}

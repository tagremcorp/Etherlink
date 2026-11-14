import Foundation
import Network
import Darwin
import SystemConfiguration

struct Adapter: Identifiable, Hashable {
    let interface: NWInterface?
    let name: String
    let address: String
    var index: Int { Int(if_nametoindex(name)) }
    init(interface: NWInterface, address: String) {
        self.interface = interface; self.name = interface.name; self.address = address
    }
    init(name: String, address: String) {
        self.interface = nil; self.name = name; self.address = address
    }
    var id: String { "\(name)/\(address)" }
    var label: String { "\(name) — \(address)" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func addresses() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        var item = head
        while let current = item {
            defer { item = current.pointee.ifa_next }
            let entry = current.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result[String(cString: entry.ifa_name), default: []].append(String(cString: host))
            }
        }
        return result
    }
    static func discover(_ path: NWPath) -> [Adapter] {
        let addresses = addresses()
        // Default NWPath omits direct adapters that have no Internet gateway.
        // Enumerate hardware first; resolve its NWInterface against the peer at connect time.
        let hardware = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return hardware.filter { SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeEthernet }
            .compactMap { SCNetworkInterfaceGetBSDName($0) as String? }
            .flatMap { name in
                (addresses[name] ?? []).map { address -> Adapter in
                    if let interface = path.availableInterfaces.first(where: { $0.name == name && $0.type == .wiredEthernet }) {
                        return Adapter(interface: interface, address: address)
                    }
                    return Adapter(name: name, address: address)
                }
            }.sorted { $0.id < $1.id }
    }
}

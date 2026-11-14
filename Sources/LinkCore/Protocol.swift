import Foundation
import Darwin

public enum LinkError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public enum Validation {
    public static func ipv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }
    public static func secret(_ text: String) throws -> Data {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 64, clean.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw LinkError.invalid("Use the 64-character pairing key generated on the other Mac.")
        }
        var bytes = Data()
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2)
            guard let byte = UInt8(clean[i..<next], radix: 16) else { throw LinkError.invalid("Invalid pairing key.") }
            bytes.append(byte); i = next
        }
        return bytes
    }
}

public struct LinkHealth {
    public private(set) var lastReceived: TimeInterval
    public init(now: TimeInterval) { lastReceived = now }
    public mutating func received(now: TimeInterval) { lastReceived = now }
    public func expired(now: TimeInterval) -> Bool { now - lastReceived > 5 }
}

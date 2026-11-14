import Foundation

/// The listening peer serializes role choices. Neither peer may share until assignment is acknowledged.
public struct PairRoles {
    public let localID: String
    public let localName: String
    public let coordinator: Bool
    public private(set) var peerID: String?
    public private(set) var peerName = "Other Mac"
    public private(set) var needsChoice = false
    public private(set) var confirmedSourceID: String?
    public private(set) var roundID: String?
    private var assignmentID: String?
    private var proposedSourceID: String?
    public var isConfirmed: Bool { confirmedSourceID != nil }
    public var localIsKeyboard: Bool? { confirmedSourceID.map { $0 == localID } }
    public init(localID: String, localName: String, coordinator: Bool) {
        self.localID = localID; self.localName = localName; self.coordinator = coordinator
    }
    public var hello: WireMessage { var m = WireMessage(.hello); m.deviceID = localID; m.deviceName = localName; return m }
    private func message(_ kind: WireMessage.Kind) -> WireMessage {
        var m = WireMessage(kind); m.roleRound = roundID; m.assignmentID = assignmentID; m.sourceDeviceID = proposedSourceID; return m
    }
    private mutating func clearAssignment() {
        assignmentID = nil; proposedSourceID = nil; confirmedSourceID = nil
    }
    private mutating func prompt() -> [WireMessage] {
        clearAssignment(); roundID = UUID().uuidString; needsChoice = true
        return [message(.rolePrompt)]
    }
    private mutating func assign(_ source: String) -> [WireMessage] {
        clearAssignment(); proposedSourceID = source; assignmentID = UUID().uuidString
        needsChoice = false
        return [message(.roleAssignment)]
    }
    public mutating func requestSetup() -> [WireMessage] {
        guard peerID != nil else { return [] }
        clearAssignment(); needsChoice = false
        return coordinator ? prompt() : [message(.roleSetupRequest)]
    }
    public mutating func choose(local: Bool) -> [WireMessage] {
        guard needsChoice, let peerID, roundID != nil else { return [] }
        let source = local ? localID : peerID
        if coordinator { return assign(source) }
        needsChoice = false
        var choice = message(.roleChoice); choice.sourceDeviceID = source
        return [choice]
    }
    public mutating func cancel() -> [WireMessage] {
        guard roundID != nil else { return [] }
        clearAssignment(); needsChoice = false
        return [message(.roleCancel)]
    }
    public mutating func receive(_ m: WireMessage, savedSourceID: String? = nil) throws -> [WireMessage] {
        switch m.kind {
        case .hello:
            guard let id = m.deviceID, UUID(uuidString: id) != nil, id != localID,
                  let name = m.deviceName, !name.isEmpty, name.count <= 80,
                  peerID == nil || peerID == id else { throw LinkError.invalid("Invalid peer identity.") }
            guard peerID == nil else { return [] }
            peerID = id; peerName = name
            if coordinator {
                if let savedSourceID, savedSourceID == localID || savedSourceID == id {
                    roundID = UUID().uuidString
                    return assign(savedSourceID)
                }
                return prompt()
            }
        case .roleSetupRequest:
            if coordinator, peerID != nil { return prompt() }
        case .rolePrompt:
            guard !coordinator, peerID != nil, let round = m.roleRound, UUID(uuidString: round) != nil else { throw LinkError.invalid("Invalid role setup request.") }
            clearAssignment(); roundID = round; needsChoice = true
        case .roleChoice:
            guard coordinator, needsChoice, m.roleRound == roundID, let source = m.sourceDeviceID,
                  source == localID || source == peerID else { return [] }
            // First valid choice wins; simultaneous/stale choices cannot create two sources.
            return assign(source)
        case .roleAssignment:
            guard !coordinator, peerID != nil, let round = m.roleRound, UUID(uuidString: round) != nil,
                  let assignment = m.assignmentID, UUID(uuidString: assignment) != nil,
                  let source = m.sourceDeviceID, source == localID || source == peerID else { throw LinkError.invalid("Invalid keyboard source assignment.") }
            clearAssignment(); roundID = round; assignmentID = assignment; proposedSourceID = source; needsChoice = false
            return [message(.roleAck)]
        case .roleAck:
            guard coordinator, let assignmentID, let proposedSourceID, m.assignmentID == assignmentID,
                  m.roleRound == roundID, m.sourceDeviceID == proposedSourceID else { return [] }
            confirmedSourceID = proposedSourceID
            return [message(.roleConfirmed)]
        case .roleConfirmed:
            guard !coordinator, let assignmentID, let proposedSourceID, m.assignmentID == assignmentID,
                  m.roleRound == roundID, m.sourceDeviceID == proposedSourceID else { return [] }
            confirmedSourceID = proposedSourceID
        case .roleCancel:
            guard m.roleRound == roundID else { return [] }
            clearAssignment(); needsChoice = false
            if coordinator { return [message(.roleCancel)] }
        default: break
        }
        return []
    }
}

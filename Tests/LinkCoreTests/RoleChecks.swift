import Foundation
import LinkCore

private struct RolePair {
    var a: PairRoles
    var b: PairRoles
    init() {
        a = PairRoles(localID: UUID().uuidString, localName: "Mac A", coordinator: true)
        b = PairRoles(localID: UUID().uuidString, localName: "Mac B", coordinator: false)
    }
    mutating func begin(saved: String? = nil) throws {
        _ = try b.receive(a.hello)
        let prompt = try a.receive(b.hello, savedSourceID: saved)
        try deliver(prompt.map { (true, $0) })
    }
    mutating func deliver(_ initial: [(Bool, WireMessage)]) throws {
        var queue = initial
        var steps = 0
        while !queue.isEmpty {
            steps += 1
            guard steps < 40 else { throw LinkError.invalid("Role negotiation did not converge.") }
            let (fromA, message) = queue.removeFirst()
            let replies = try fromA ? b.receive(message) : a.receive(message)
            queue += replies.map { (!fromA, $0) }
        }
    }
    func checkSource(_ source: String) throws {
        try CoreChecks.check(a.isConfirmed && b.isConfirmed, "both assignments acknowledged")
        try CoreChecks.check(a.confirmedSourceID == source && b.confirmedSourceID == source, "both peers agree on the source")
        try CoreChecks.check(a.localIsKeyboard != b.localIsKeyboard, "exactly one keyboard source")
    }
}

extension CoreChecks {
    static func roleChecks() throws {
        for chooseOnA in [true, false] {
            for useLocal in [true, false] {
                var pair = RolePair(); try pair.begin()
                try check(pair.a.needsChoice && pair.b.needsChoice, "both screens prompt on first connection")
                try check(pair.a.localIsKeyboard == nil && pair.b.localIsKeyboard == nil, "no independent default roles before agreement")
                let source = chooseOnA == useLocal ? pair.a.localID : pair.b.localID
                let messages = chooseOnA ? pair.a.choose(local: useLocal) : pair.b.choose(local: useLocal)
                try check(!pair.a.isConfirmed && !pair.b.isConfirmed, "selection alone does not authorize control")
                try pair.deliver(messages.map { (chooseOnA, $0) })
                try pair.checkSource(source)
            }
        }
        // Both users claim their own keyboard at once: the coordinator serializes the outcome.
        var simultaneous = RolePair(); try simultaneous.begin()
        let localChoice = simultaneous.a.choose(local: true)
        let remoteChoice = simultaneous.b.choose(local: true)
        try simultaneous.deliver(remoteChoice.map { (false, $0) } + localChoice.map { (true, $0) })
        try simultaneous.checkSource(simultaneous.a.localID)
        // A stale acknowledgement cannot enable sharing after a new setup begins.
        var stale = RolePair(); try stale.begin()
        let assignment = stale.a.choose(local: true)[0]
        let ack = try stale.b.receive(assignment)[0]
        let newPrompt = stale.a.requestSetup()
        _ = try stale.a.receive(ack)
        try check(!stale.a.isConfirmed, "stale ack rejected")
        try stale.deliver(newPrompt.map { (true, $0) })
        try check(stale.a.needsChoice && stale.b.needsChoice, "reconfiguration prompts on both screens")
        try stale.deliver(stale.b.cancel().map { (false, $0) })
        try check(!stale.a.isConfirmed && !stale.b.isConfirmed && !stale.a.needsChoice && !stale.b.needsChoice, "cancellation pauses both peers")
        // Saved choices are validated against the newly authenticated peer, then acknowledged again.
        var saved = RolePair(); try saved.begin(saved: saved.b.localID)
        try saved.checkSource(saved.b.localID)
        try check(!saved.a.needsChoice && !saved.b.needsChoice, "reconnect restores the agreed source without another prompt")
        var invalidSaved = RolePair(); try invalidSaved.begin(saved: UUID().uuidString)
        try check(invalidSaved.a.needsChoice && invalidSaved.b.needsChoice, "unknown saved source requires a fresh choice")
        var invalid = RolePair(); try invalid.begin()
        var wrong = WireMessage(.roleAssignment)
        wrong.roleRound = UUID().uuidString; wrong.assignmentID = UUID().uuidString; wrong.sourceDeviceID = UUID().uuidString
        try rejects("third-device source assignment") { _ = try invalid.b.receive(wrong) }
        print("PASS coordinated keyboard source: both prompts, all choices, simultaneous choices, stale ack, cancel and reconnect")
    }
}

#if targetEnvironment(simulator)
import Foundation
import WatchConnectivity

/// WatchConnectivity owns this callback; the box crosses to the main actor once.
final class SimulatorReply: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func call(_ reply: [String: Any]) { handler(reply) }
}

enum SimulatorConnectivity {
    static func send(_ payload: [String: Any], session: WCSession) async throws {
        guard session.isReachable else { throw MapError.invalid("模拟器前台通道不可用，请同时打开两端 App。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.sendMessage(payload, replyHandler: { reply in
                if let message = reply["error"] as? String { continuation.resume(throwing: MapError.invalid(message)) }
                else { continuation.resume() }
            }, errorHandler: { continuation.resume(throwing: $0) })
        }
    }
}
#endif

import Foundation

struct HelperCommandEvent: Codable {
    let id: UUID
    let commandID: UUID
    let command: String
    let stage: String
    let elapsed: TimeInterval
    let exitCode: Int32?
    let timedOut: Bool
}

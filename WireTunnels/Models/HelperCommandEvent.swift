import Foundation

struct HelperCommandEvent: Codable {
    let id: UUID
    let commandID: UUID
    let command: String
    let stage: String
    let elapsed: TimeInterval
    let exitCode: Int32?
    let timedOut: Bool
    /// Set for helper messages outside a command run, like tool reinstalls; nil for command stages.
    var message: String? = nil
    var isError: Bool? = nil
}

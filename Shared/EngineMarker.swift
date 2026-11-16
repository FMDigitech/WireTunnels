import Foundation

/// How the app tells the helper to run a plain config on AmneziaWG. The helper picks the quick
/// tool from the config text it stages itself, so the request travels as a comment line the
/// app adds to the staged copy only: the user's own file is never touched. wg-quick and
/// awg-quick both ignore comments, so the config stays valid for either tool.
///
/// The marker can only ask for awg. A config that uses AmneziaWG keys always runs on awg
/// (wg cannot read them), and awg-quick runs a plain config as plain WireGuard, so honouring
/// the request gives a client of the helper no more than it already had.
enum EngineMarker {
    static let amneziaWGLine = "# WireTunnels-Engine: amneziawg"

    /// True for a comment line that is exactly the marker, ignoring case and surrounding spaces.
    static func isMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased() == amneziaWGLine.lowercased()
    }

    static func requestsAmneziaWG(in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains(where: isMarker)
    }

    /// The config text with the marker as its first line, unless it already has one.
    static func addingAmneziaWGMarker(to text: String) -> String {
        requestsAmneziaWG(in: text) ? text : amneziaWGLine + "\n" + text
    }
}

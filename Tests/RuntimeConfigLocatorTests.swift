import Foundation

@main
struct RuntimeConfigLocatorTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let paths = try RuntimeConfigLocator.configPaths(in: directory) { name in
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard paths["utun7"] == directory.appendingPathComponent("full.conf").path,
              paths.count == 1 else {
            print("FAIL: runtime mapping must resolve the original config and reject stale or invalid sockets")
            exit(1)
        }
        guard try RuntimeConfigLocator.hasUserspaceSockets(in: directory),
              try !RuntimeConfigLocator.hasUserspaceSockets(in: directory.appendingPathComponent("absent")) else {
            fatalError("Missing tools must not hide a surviving userspace socket")
        }
        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("utun13.sock"))
        guard try !RuntimeConfigLocator.hasUserspaceSockets(in: empty) else {
            fatalError("A regular file must not count as a userspace interface")
        }
        let missing = try RuntimeConfigLocator.configPaths(in: directory.appendingPathComponent("absent")) { _ in nil }
        guard missing.isEmpty else { exit(1) }
        print("PASS: runtime config discovery validates aliases and socket lifetimes")
    }
}

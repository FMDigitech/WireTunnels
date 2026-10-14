import Darwin
import Foundation

if let operation = CommandLine.arguments.dropFirst().first, operation.hasPrefix("--dns-") {
    do {
        try DNSRecoveryCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(0)
    } catch {
        // Arguments and network settings can contain private addresses or names.
        FileHandle.standardError.write(Data("DNS recovery failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let helperTool = HelperTool()
helperTool.run()

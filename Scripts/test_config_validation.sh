#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsConfigValidationTest.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard condition() else {
        fatalError(message, file: file, line: line)
    }
}

let parser = WireGuardConfigParser()

let missingValues = parser.parse(string: """
[Interface]
DNS = 1.1.1.1

[Peer]
Endpoint = vpn.example.com:51820
""")

require(!missingValues.isValid, "A config missing required values must be invalid")
require(
    Set(missingValues.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Every missing required value must produce a typed blocking error"
)
require(missingValues.warnings.isEmpty, "Present optional values must not warn")

let malformedSections = parser.parse(string: """
[FakeInterface]
PrivateKey = private-key
Address = 10.0.0.2/32

[NotPeer]
PublicKey = peer-key
AllowedIPs = 0.0.0.0/0
""")

require(!malformedSections.isValid, "Only exact Interface and Peer section names are valid")
require(
    Set(malformedSections.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Malformed section names must not satisfy required fields"
)

let explicitlyEmpty = parser.parse(string: """
[Interface]
PrivateKey =
Address = , ,
DNS = ,

[Peer]
PublicKey =
Endpoint =
AllowedIPs = ,
""")

require(!explicitlyEmpty.isValid, "Explicitly empty required values must be invalid")
require(
    Set(explicitlyEmpty.validationErrors) == [
        .missingPrivateKey,
        .missingAddress,
        .missingPeerPublicKey,
        .missingAllowedIPs
    ],
    "Empty assignments must be treated as missing required values"
)
require(
    Set(explicitlyEmpty.warnings) == [.missingDNS, .missingEndpoint],
    "Empty optional assignments must retain non-blocking warnings"
)

let warningOnly = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = first-peer-key
AllowedIPs = 0.0.0.0/0

[Peer]
PublicKey = ignored-peer-key
AllowedIPs = 10.0.0.0/8
""")

require(warningOnly.isValid, "Non-blocking warnings must not invalidate a config")
require(warningOnly.validationErrors.isEmpty, "A valid config must have no blocking errors")
require(
    Set(warningOnly.warnings) == [
        .missingDNS,
        .missingEndpoint,
        .fullTunnel,
        .multiplePeers
    ],
    "DNS, endpoint, full tunnel, and multiple peers must remain warnings"
)

// The parser reports the first privileged hook it finds (the helper rejects the same
// configs), so each directive is checked on its own, in both sections.
let hookDirectives = ["PreUp", "PostUp", "PreDown", "PostDown"]
for directive in hookDirectives {
    for section in ["Interface", "Peer"] {
        let interfaceHook = section == "Interface" ? "\(directive) = touch /tmp/wiretunnels-root-hook" : ""
        let peerHook = section == "Peer" ? "\(directive) = touch /tmp/wiretunnels-root-hook" : ""
        let config = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
\(interfaceHook)

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
\(peerHook)
""")
        require(!config.isValid, "\(directive) in [\(section)] must be rejected")
        require(
            config.validationErrors == [.unsupportedDirective(directive)],
            "\(directive) in [\(section)] must produce a blocking validation error"
        )
    }
}

let mixedCaseHook = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
pOsTuP=touch /tmp/x

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
""")
require(
    mixedCaseHook.validationErrors == [.unsupportedDirective("PostUp")],
    "Hook directives must be rejected case-insensitively"
)

// AmneziaWG: extra Interface/Peer keys mark the config as needing awg, and awg exits on a
// malformed value, so values are validated with its own rules at import.
let plain = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
""")
require(!plain.usesAmneziaWG && plain.amneziaInterface.isEmpty, "A plain WireGuard config must not be flagged as AmneziaWG")

let headerKey = Data(repeating: 7, count: 32).base64EncodedString()
let amnezia = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
Jc = 5   # junk packet count
jmin = 40
Jmax = 70
S1 = 15
S2 = 18
H1 = 1000-2000
H2 = 3000
I1 = <b 0xc7000000><r 16>
HeaderProtectionKey = \(headerKey)
RandomTrailers = on
ContentPaddingAddition = 10-20

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
AdvancedSecurity = 1
""")
require(amnezia.isValid, "A well-formed AmneziaWG config must be valid: \(amnezia.validationErrors)")
require(amnezia.usesAmneziaWG, "AmneziaWG keys must mark the config as AmneziaWG")
require(amnezia.amneziaInterface.map(\.name) == ["Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "I1", "HeaderProtectionKey", "RandomTrailers", "ContentPaddingAddition"],
        "Keys must be kept with their canonical names, in file order: \(amnezia.amneziaInterface.map(\.name))")
require(amnezia.amneziaInterface.first?.value == "5", "A trailing comment must not become part of the value")
require(amnezia.amneziaInterface.first { $0.name == "I1" }?.value == "<b 0xc7000000><r 16>", "Signature chains must be kept verbatim")
require(amnezia.amneziaPeer.map(\.name) == ["AdvancedSecurity"], "The peer AdvancedSecurity key must be kept")

let peerOnly = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
AdvancedSecurity = on
""")
require(peerOnly.usesAmneziaWG, "AdvancedSecurity alone must mark the config as AmneziaWG")

// Keys only count in the section awg reads them from.
let wrongSection = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
Jc = 5
""")
require(!wrongSection.usesAmneziaWG, "An Interface key in the Peer section must not be read")

for (line, label) in [
    ("Jc = 70000", "Jc above 65535"),
    ("Jc = five", "Jc that is not a number"),
    ("Jc = -1", "a negative Jc"),
    ("Jc =", "an empty Jc"),
    ("H1 = 5-3", "a descending H1 range"),
    ("H1 = 4294967296", "H1 above 32 bits"),
    ("H2 = 1-", "an open H2 range"),
    ("I1 =", "an empty I1"),
    ("HeaderProtectionKey = not-a-key", "a malformed HeaderProtectionKey"),
    ("RandomTrailers = maybe", "a non-boolean flag"),
    ("ContentPaddingAddition = 70000", "a 16-bit range above 65535")
] {
    let config = parser.parse(string: """
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
\(line)

[Peer]
PublicKey = peer-key
AllowedIPs = 10.0.0.0/8
""")
    require(!config.isValid, "\(label) must be rejected")
    require(config.validationErrors.count == 1, "\(label) must give one error: \(config.validationErrors)")
}

print("Configuration validation checks passed")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Services/WireGuardConfigParser.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_config_validation"

"${TEST_DIR}/test_config_validation"

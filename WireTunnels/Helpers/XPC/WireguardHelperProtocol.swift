import Foundation

@objc protocol WireguardHelperProtocol {
    func startTunnel(named name: String, reply: @escaping (Bool, String?) -> Void)
    func stopTunnel(named name: String, reply: @escaping (Bool, String?) -> Void)
    func runWgShow(reply: @escaping (String?, String?) -> Void)
    func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void)
    func stageConfig(named name: String, contents: Data, reply: @escaping (Bool, String?) -> Void)
    func installBundledTools(reply: @escaping (Bool, String?) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
}

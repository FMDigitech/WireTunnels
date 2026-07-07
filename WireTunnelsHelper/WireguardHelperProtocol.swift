import Foundation

@objc protocol WireguardHelperProtocol {
    func startTunnel(named name: String, reply: @escaping (Bool, String?) -> Void)
    func stopTunnel(named name: String, reply: @escaping (Bool, String?) -> Void)
    func runWgShow(reply: @escaping (String?, String?) -> Void)
    func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void)
    func stageConfig(named name: String, contents: Data, reply: @escaping (Bool, String?) -> Void)
    func listManagedTunnels(reply: @escaping (Data?, String?) -> Void)
    func installManagedTunnel(named name: String, contents: Data, authorization: Data, reply: @escaping (Bool, String?) -> Void)
    func updateManagedTunnel(id: String, name: String, contents: Data?, policy: Data, autoConnectRule: Data, authorization: Data, reply: @escaping (Bool, String?) -> Void)
    func deleteManagedTunnel(id: String, authorization: Data, reply: @escaping (Bool, String?) -> Void)
    func stageManagedConfig(id: String, reply: @escaping (String?, String?) -> Void)
    func markManagedTunnelConnected(id: String, reply: @escaping (Bool, String?) -> Void)
    func markManagedTunnelDisconnected(id: String, reply: @escaping (Bool, String?) -> Void)
    func listManagedTunnelUsers(id: String, authorization: Data, reply: @escaping (Data?, String?) -> Void)
    func installBundledTools(reply: @escaping (Bool, String?) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
    func helperProtocolRevision(reply: @escaping (String) -> Void)
}

import Foundation

extension TunnelManager {
    private func inventoryRequest(_ tunnel: Tunnel, action: InventoryRoutingRequest.Action,
                                  discovered: [String]? = nil) throws -> InventoryRoutingRequest {
        if action == .remove { return .removal(ownerID: tunnel.id) }
        let parsed = try WireGuardConfigParser().parse(contentsOf: URL(fileURLWithPath: tunnel.configPath))
        guard parsed.isValid, !parsed.warnings.contains(.multiplePeers), let peer = parsed.peerPublicKey,
              let local = parsed.privateKey.flatMap(WireGuardKey.publicKey(fromPrivateKey:)),
              let generation = inventoryGenerations[tunnel.id] else { throw InventoryError.invalidOutput }
        return InventoryRoutingRequest(action: action, ownerID: tunnel.id, generation: generation,
            configName: URL(fileURLWithPath: tunnel.configPath).lastPathComponent,
            localPublicKey: local, peerPublicKey: peer,
            staticPrefixes: try IPPrefix.normalized(parsed.allowedIPs),
            discoveredPrefixes: discovered ?? tunnel.inventoryAllowedIPs)
    }

    func updateInventoryCommand(for tunnel: Tunnel, command: InventoryCommand?) async throws {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }), tunnels[index].scope == .personal,
              !tunnels[index].isActive, !isTunnelBusy(tunnel.id), !refreshingInventories.contains(tunnel.id) else {
            throw InventoryError.operation("Disconnect this personal tunnel before changing its inventory command")
        }
        if command != nil, tunnels[index].engine == .amneziaWG {
            throw InventoryError.operation("Inventory protection does not support AmneziaWG tunnels")
        }
        if let command {
            guard command.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command.executable),
                  tunnels[index].excludedRoutes.isEmpty,
                  !hopChains.contains(where: { $0.hopTunnelID == tunnel.id || $0.exitTunnelID == tunnel.id }) else {
                throw InventoryError.operation("Choose an executable using an absolute path. Inventory protection cannot be combined with bypass routes or hop chains.")
            }
        }
        connectingTunnels.insert(tunnel.id)
        defer { connectingTunnels.remove(tunnel.id) }
        inventoryGenerations[tunnel.id] = UUID()
        let previous = tunnels[index]
        let request = try inventoryRequest(tunnels[index], action: command == nil ? .remove : .protect)
        try await commandService.updateInventoryRouting(request)
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }), !tunnels[index].isActive else {
            try? await commandService.updateInventoryRouting(.removal(ownerID: tunnel.id))
            throw InventoryError.staleOperation
        }
        tunnels[index].inventoryCommand = command
        if command == nil { tunnels[index].inventoryAllowedIPs = []; tunnels[index].inventoryUpdatedAt = nil }
        tunnels[index].updatedAt = Date()
        do { try saveInventoryTunnels() }
        catch {
            tunnels[index] = previous
            if let rollback = try? inventoryRequest(previous, action: previous.inventoryCommand == nil ? .remove : .protect) {
                try? await commandService.updateInventoryRouting(rollback)
            }
            throw error
        }
        inventoryErrors.removeValue(forKey: tunnel.id)
    }

    func protectInventory(_ tunnel: Tunnel) async throws {
        inventoryGenerations[tunnel.id] = UUID()
        inventoryTasks[tunnel.id]?.cancel()
        if let task = inventoryTasks[tunnel.id] { _ = try? await task.value }
        let current = tunnels.first(where: { $0.id == tunnel.id }) ?? tunnel
        try await commandService.updateInventoryRouting(inventoryRequest(current, action: .protect))
    }

    func applyCachedInventory(_ tunnel: Tunnel) async throws {
        let current = tunnels.first(where: { $0.id == tunnel.id }) ?? tunnel
        var request = try inventoryRequest(current, action: .apply)
        request.useCachedInventory = true
        try await commandService.updateInventoryRouting(request)
    }

    func refreshInventory(for tunnel: Tunnel) async {
        guard let current = tunnels.first(where: { $0.id == tunnel.id }), current.isActive,
              let command = current.inventoryCommand, !refreshingInventories.contains(tunnel.id),
              let generation = inventoryGenerations[tunnel.id] else { return }
        refreshingInventories.insert(tunnel.id)
        inventoryErrors.removeValue(forKey: tunnel.id)
        defer { refreshingInventories.remove(tunnel.id); inventoryTasks.removeValue(forKey: tunnel.id) }
        let task = Task { try await InventoryCommandService.run(command) }
        inventoryTasks[tunnel.id] = task
        do {
            let prefixes = try await task.value
            guard inventoryGenerations[tunnel.id] == generation,
                  let live = tunnels.first(where: { $0.id == tunnel.id }), live.isActive else { throw InventoryError.staleOperation }
            let request = try inventoryRequest(live, action: .apply, discovered: prefixes)
            try await commandService.updateInventoryRouting(request)
            guard inventoryGenerations[tunnel.id] == generation,
                  let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { throw InventoryError.staleOperation }
            tunnels[index].inventoryAllowedIPs = prefixes
            tunnels[index].inventoryUpdatedAt = Date()
            tunnels[index].allowedIPs = try IPPrefix.normalized(request.staticPrefixes + prefixes)
            try saveInventoryTunnels()
        } catch is CancellationError {
        } catch {
            if inventoryGenerations[tunnel.id] == generation { inventoryErrors[tunnel.id] = error.localizedDescription }
        }
    }
}

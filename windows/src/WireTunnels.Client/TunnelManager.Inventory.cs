using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.Client;

/// Inventory AllowedIPs (port of TunnelInventoryIntegration.swift): the app runs the tunnel's inventory
/// command as the user; the service applies the validated prefixes and keeps the destinations blocked
/// outside the tunnel, including while it is disconnected, until the command is removed.
public sealed partial class TunnelManager
{
    private readonly Dictionary<Guid, Guid> _inventoryGenerations = [];
    private readonly Dictionary<Guid, CancellationTokenSource> _inventoryRuns = [];
    private readonly Dictionary<Guid, string> _inventoryErrors = [];

    public string? InventoryErrorOf(Guid id) => _inventoryErrors.GetValueOrDefault(id);
    public bool IsRefreshingInventory(Guid id) => _inventoryRuns.ContainsKey(id);

    private async Task<InventoryRoutingRequest> InventoryRequestAsync(Tunnel tunnel, InventoryAction action, IReadOnlyList<string>? discovered = null)
    {
        if (action == InventoryAction.Remove) return InventoryRoutingRequest.Removal(tunnel.Id);
        var parsed = WireGuardConfig.Parse(ReadConfig(tunnel.Id));
        if (!parsed.IsValid || parsed.Peers.Count != 1 || parsed.PrimaryPeer?.PublicKey is not { } peer || parsed.PrivateKey is not { } key
            || WireGuardKey.PublicKey(key) is not { } localKey
            || _configs.AliasOf(tunnel.ConfigPath) is not { } alias || !_inventoryGenerations.TryGetValue(tunnel.Id, out var generation))
            throw InventoryException.InvalidOutput();
        var endpoint = parsed.PrimaryPeer.Endpoint is { } text ? Endpoint.TryParse(text) : null;
        var address = endpoint is null ? null : await _network.ResolveAsync(endpoint.Host);
        return new InventoryRoutingRequest
        {
            Action = action, OwnerId = tunnel.Id, Generation = generation, Name = alias,
            LocalPublicKey = localKey, PeerPublicKey = peer,
            StaticPrefixes = [.. IPPrefix.Normalized(parsed.PrimaryPeer.AllowedIPs)],
            DiscoveredPrefixes = [.. discovered ?? tunnel.InventoryAllowedIPs],
            EndpointHost = address?.ToString(), EndpointPort = endpoint?.Port ?? 0,
        };
    }

    /// Sets or removes (null) the command; only while the tunnel is disconnected. Setting it installs the block at once.
    public async Task UpdateInventoryCommandAsync(Guid id, InventoryCommand? command)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal, IsActive: false } tunnel || IsBusy(id) || IsRefreshingInventory(id))
            throw new InventoryException("Disconnect this personal tunnel before changing its inventory command");
        if (command is not null && (!InventoryCommandRunner.IsValid(command) || tunnel.ExcludedRoutes.Count > 0 || ChainOf(id) is not null))
            throw new InventoryException("Choose an executable using an absolute path. Inventory protection cannot be combined with bypass routes or hop chains.");
        _connecting.Add(id);
        Notify();
        try
        {
            _inventoryGenerations[id] = Guid.NewGuid();
            var previous = Clone(tunnel);
            await _service.UpdateInventoryAsync(await InventoryRequestAsync(tunnel, command is null ? InventoryAction.Remove : InventoryAction.Protect));
            if (Find(id) is not { IsActive: false } live)
            {
                await TryAsync(() => _service.UpdateInventoryAsync(InventoryRoutingRequest.Removal(id)));
                throw InventoryException.Stale();
            }
            live.InventoryCommand = command;
            if (command is null)
            {
                live.InventoryAllowedIPs = [];
                live.InventoryUpdatedAt = null;
            }
            live.UpdatedAt = Now;
            try { PersistPersonalTunnels(_tunnels); }
            catch (IOException)
            {
                // The saved metadata must keep describing what the service enforces.
                live.InventoryCommand = previous.InventoryCommand;
                live.InventoryAllowedIPs = previous.InventoryAllowedIPs;
                live.InventoryUpdatedAt = previous.InventoryUpdatedAt;
                await TryAsync(async () => await _service.UpdateInventoryAsync(await InventoryRequestAsync(previous,
                    previous.InventoryCommand is null ? InventoryAction.Remove : InventoryAction.Protect)));
                throw;
            }
            _inventoryErrors.Remove(id);
            _log.Info(command is null ? $"Inventory protection removed from {tunnel.Name}" : $"Inventory command set for {tunnel.Name}");
        }
        finally
        {
            _connecting.Remove(id);
            Notify();
        }
    }

    /// Blocks the destinations everywhere and starts a new generation, cancelling a running fetch.
    private async Task ProtectInventoryAsync(Tunnel tunnel)
    {
        _inventoryGenerations[tunnel.Id] = Guid.NewGuid();
        if (_inventoryRuns.TryGetValue(tunnel.Id, out var run)) run.Cancel();
        await _service.UpdateInventoryAsync(await InventoryRequestAsync(Find(tunnel.Id) ?? tunnel, InventoryAction.Protect));
    }

    /// Opens the cached destinations through the just-connected tunnel, before fetching a fresh list.
    private async Task ApplyCachedInventoryAsync(Tunnel tunnel)
    {
        var request = await InventoryRequestAsync(Find(tunnel.Id) ?? tunnel, InventoryAction.Apply);
        request.UseCachedInventory = true;
        await _service.UpdateInventoryAsync(request);
    }

    /// Runs the command and applies its output; a failure keeps the last good inventory.
    public async Task RefreshInventoryAsync(Guid id)
    {
        if (Find(id) is not { IsActive: true, InventoryCommand: { } command } || IsRefreshingInventory(id)
            || !_inventoryGenerations.TryGetValue(id, out var generation)) return;
        var cts = _inventoryRuns[id] = new CancellationTokenSource();
        _inventoryErrors.Remove(id);
        Notify();
        try
        {
            var prefixes = await _inventory.RunAsync(command, cts.Token);
            if (_inventoryGenerations.GetValueOrDefault(id) != generation || Find(id) is not { IsActive: true } live) throw InventoryException.Stale();
            var request = await InventoryRequestAsync(live, InventoryAction.Apply, prefixes);
            await _service.UpdateInventoryAsync(request);
            if (_inventoryGenerations.GetValueOrDefault(id) != generation || Find(id) is not { } current) throw InventoryException.Stale();
            current.InventoryAllowedIPs = [.. prefixes];
            current.InventoryUpdatedAt = Now;
            current.AllowedIPs = [.. IPPrefix.Normalized([.. request.StaticPrefixes, .. prefixes])];
            SavePersonalTunnels();
            _log.Info($"Inventory of {current.Name}: {prefixes.Count} prefix(es)");
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is InventoryException || IsServiceFailure(e))
        {
            if (_inventoryGenerations.GetValueOrDefault(id) == generation)
            {
                _inventoryErrors[id] = e.Message;
                _log.Warning($"Inventory refresh failed: {e.Message}");
            }
        }
        finally
        {
            _inventoryRuns.Remove(id);
            cts.Dispose();
            UpdateWarnings();
            Notify();
        }
    }

    /// After a connect (also at startup for a tunnel still running): cached list first, then a fresh fetch.
    private async Task OpenInventoryAsync(Tunnel tunnel)
    {
        try
        {
            await ApplyCachedInventoryAsync(tunnel);
            _ = RefreshInventoryAsync(tunnel.Id);
        }
        catch (Exception e) when (e is InventoryException || IsServiceFailure(e) || e is System.Security.Cryptography.CryptographicException)
        {
            _inventoryErrors[tunnel.Id] = e.Message;
            _log.Warning($"Inventory of {tunnel.Name} could not be applied: {e.Message}");
        }
    }

    /// Startup: every inventory tunnel is protected again; the connected ones reopen their path.
    private async Task RestoreInventoryAsync()
    {
        foreach (var tunnel in _tunnels.Where(t => t.InventoryCommand is not null).ToList())
        {
            try
            {
                await ProtectInventoryAsync(tunnel);
                if (tunnel.IsActive) await OpenInventoryAsync(tunnel);
            }
            catch (Exception e) when (e is InventoryException || IsServiceFailure(e) || e is System.Security.Cryptography.CryptographicException)
            {
                _inventoryErrors[tunnel.Id] = e.Message;
            }
        }
    }
}

using CommunityToolkit.Mvvm.ComponentModel;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;

namespace WireTunnels.Client;

/// Shared (managed) tunnels, port of the macOS managed-tunnel half of TunnelManager.swift. The service keeps them:
/// every user sees them and can connect them (as the policy allows), only an administrator changes them, and each
/// change goes through UAC (ITunnelService.AdminAsync). As on macOS, quitting the app (or resetting its data)
/// disconnects them too, for every user; a policy that forbids disconnecting makes the quit fail with Retry / Cancel.
public sealed partial class TunnelManager
{
    private static readonly TimeSpan ManagedRefreshInterval = TimeSpan.FromSeconds(10);
    private DateTimeOffset _managedLoadedAt = DateTimeOffset.MinValue;
    private string? _lastManagedSnapshot;

    /// Device-wide settings set by an administrator.
    [ObservableProperty] private SystemSettings _systemSettings = new();

    /// Whether to offer the administrator actions (an administrator account; the app wires Elevation.CanAdminister).
    public bool CanAdminister => _canAdminister();

    /// The adapter alias: the stored config's file name, or for a shared tunnel the alias the service gave it.
    private string? AliasOf(Tunnel tunnel) => tunnel.Scope == TunnelScope.Managed
        ? ConfigName.IsValidAlias(tunnel.ConfigPath) ? tunnel.ConfigPath : null
        : _configs.AliasOf(tunnel.ConfigPath);

    /// Port of loadManagedTunnels: replaces the shared entries, keeping their runtime state.
    public async Task<bool> LoadManagedTunnelsAsync()
    {
        IReadOnlyList<Tunnel> managed;
        try { managed = await _service.ListManagedAsync(); }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Warning($"Unable to load shared tunnels: {e.Message}");
            return false;
        }
        _managedLoadedAt = Now;
        var snapshot = System.Text.Json.JsonSerializer.Serialize(managed, Core.Storage.CoreJson.Options);
        var existing = _tunnels.Where(t => t.Scope == TunnelScope.Managed).ToDictionary(t => t.Id);
        foreach (var tunnel in managed)
        {
            tunnel.Scope = TunnelScope.Managed;
            if (existing.TryGetValue(tunnel.Id, out var old)) CopyRuntime(old, tunnel);
        }
        _tunnels = [.. _tunnels.Where(t => t.Scope == TunnelScope.Personal), .. managed];
        if (snapshot != _lastManagedSnapshot) _log.Info($"Loaded {managed.Count} shared tunnel(s)");
        _lastManagedSnapshot = snapshot;
        RetainFeedback();
        UpdateWarnings();
        Notify();
        return true;
    }

    public async Task LoadSystemSettingsAsync()
    {
        try { SystemSettings = await _service.GetSystemSettingsAsync(); }
        catch (Exception e) when (IsServiceFailure(e)) { _log.Warning($"Unable to load system settings: {e.Message}"); }
    }

    /// Port of makeTunnelShared: the service gets a copy for every user, then the personal tunnel goes.
    public async Task MakeSharedAsync(Guid id)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        if (IsBusy(id)) throw new InvalidOperationException("Wait for the current operation on this tunnel to finish.");
        if (tunnel.IsActive) throw new InvalidOperationException("Disconnect this tunnel before making it shared.");
        if (tunnel.InventoryCommand is not null) throw new InvalidOperationException("Disable inventory protection before making this tunnel shared.");
        if (_hopChains.Any(c => c.HopTunnelID == id || c.ExitTunnelID == id))
            throw new InvalidOperationException("Remove this tunnel from its multi-hop chains before making it shared.");
        var contents = _configs.Read(tunnel.ConfigPath);
        await _service.AdminAsync<Tunnel>(Ops.InstallManaged, new InstallManagedArgs { Name = tunnel.Name, Contents = contents });
        var list = _tunnels.Where(t => t.Id != id).ToList();
        try { PersistPersonalTunnels(list); }
        catch (IOException e)
        {
            // Other users can already see the shared copy: keep both rather than lose either.
            await LoadManagedTunnelsAsync();
            throw new IOException($"The shared copy was created, but the personal tunnel could not be removed from saved metadata. Both copies were kept: {e.Message}");
        }
        _tunnels = list;
        _configs.Delete(tunnel.ConfigPath);
        await LoadManagedTunnelsAsync();
        _log.Info($"Made tunnel shared for all users: {tunnel.Name}");
    }

    public async Task<string> ReadManagedConfigAsync(Guid id) =>
        await _service.AdminAsync<string>(Ops.ReadManaged, new ManagedIdArgs { Id = id })
            ?? throw new InvalidDataException("The shared tunnel's configuration is empty.");

    /// Renames it and, with `contents`, replaces its config (it must be disconnected for either).
    public async Task UpdateManagedAsync(Guid id, string name, string? contents)
    {
        if (Find(id) is not { Scope: TunnelScope.Managed } tunnel) return;
        if (contents is not null && WireGuardConfig.Parse(contents) is { IsValid: false } parsed)
            throw new ConfigValidationException(parsed.Errors.Select(e => e.Message));
        await SendManagedUpdateAsync(tunnel, ConfigName.DisplayName(name), contents, tunnel.ManagedPolicy ?? new(), tunnel.AutoConnectRule);
        _log.Info($"Updated shared tunnel: {name}");
    }

    /// Access, kill switch and split DNS of a shared tunnel; applied to every user.
    public async Task UpdateManagedPolicyAsync(Guid id, ManagedTunnelPolicy policy)
    {
        if (Find(id) is not { Scope: TunnelScope.Managed } tunnel) return;
        policy.SplitDNSDomains = NormalizedUniqueDomains(policy.SplitDNSDomains);
        await SendManagedUpdateAsync(tunnel, tunnel.Name, null, policy, tunnel.AutoConnectRule);
        if (Find(id) is { } live)
        {
            if (live is { IsActive: true, IsKillSwitchEnabled: true }) await ArmKillSwitchAsync(live);
            else if (!live.IsKillSwitchEnabled) await DisarmKillSwitchAsync(live);
        }
        _log.Info($"Policy updated for shared tunnel {tunnel.Name}: connect={policy.UsersCanConnect} disconnect={policy.UsersCanDisconnect} "
            + $"killSwitch={policy.KillSwitchEnabled} splitDNS={policy.SplitDNSDomains.Count}");
    }

    private async Task SendManagedUpdateAsync(Tunnel tunnel, string name, string? contents, ManagedTunnelPolicy policy, AutoConnectRule rule)
    {
        if (IsBusy(tunnel.Id)) throw new InvalidOperationException("Wait for the current operation on this tunnel to finish.");
        await _service.AdminAsync<object>(Ops.UpdateManaged, new UpdateManagedArgs
        {
            Id = tunnel.Id, Name = name, Contents = contents, Policy = policy, AutoConnectRule = rule,
        });
        await LoadManagedTunnelsAsync();
    }

    public async Task DeleteManagedAsync(Guid id)
    {
        if (Find(id) is not { Scope: TunnelScope.Managed } tunnel) return;
        await _service.AdminAsync<object>(Ops.DeleteManaged, new ManagedIdArgs { Id = id });
        await DisarmKillSwitchAsync(tunnel);
        await LoadManagedTunnelsAsync();
        _log.Info($"Deleted shared tunnel: {tunnel.Name}");
    }

    public async Task<IReadOnlyList<ManagedTunnelUserSession>> ConnectedUsersAsync(Guid id) =>
        await _service.AdminAsync<List<ManagedTunnelUserSession>>(Ops.ListManagedUsers, new ManagedIdArgs { Id = id }) ?? [];

    public async Task SetRequireAdminToDisableLaunchAtLoginAsync(bool enabled)
    {
        await _service.AdminAsync<object>(Ops.SetSystemSettings, new SystemSettings { RequireAdminToDisableLaunchAtLogin = enabled });
        await LoadSystemSettingsAsync();
        _log.Info($"System setting updated: requireAdminToDisableLaunchAtLogin={enabled}");
    }

    /// Turning off Launch at Login: allowed outright, or after an administrator approves a UAC prompt.
    /// shortcut: a deterrent like the macOS one; a user can still delete the Run key by hand.
    public async Task<bool> AuthorizeDisablingLaunchAtLoginAsync()
    {
        await LoadSystemSettingsAsync();
        if (!SystemSettings.RequireAdminToDisableLaunchAtLogin) return true;
        try
        {
            await _service.AdminAsync<SystemSettings>(Ops.GetSystemSettings, null);
            return true;
        }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Info($"Disabling Launch at Login was not authorized: {e.Message}");
            return false;
        }
    }
}

namespace WireTunnels.Client;

public enum ConnectionStatus { Idle, Connected, Connecting, Reconnecting, ConnectionLost }

public static class ConnectionStatusText
{
    public static string Describe(ConnectionStatus status) => status switch
    {
        ConnectionStatus.Idle => "No tunnels connected",
        ConnectionStatus.Connected => "Connected",
        ConnectionStatus.Connecting => "Connecting...",
        ConnectionStatus.Reconnecting => "Reconnecting...",
        _ => "Connection lost",
    };
}

/// Port of TunnelConnectionFeedback.swift: background connection feedback, kept separate from
/// the alerts raised for user actions.
public sealed class ConnectionFeedback
{
    private readonly Dictionary<Guid, ConnectionStatus> _activity = [];
    private readonly Dictionary<Guid, string> _issues = [];

    public IReadOnlyDictionary<Guid, string> Issues => _issues;

    public void Begin(Guid id, bool reconnecting) =>
        _activity[id] = reconnecting ? ConnectionStatus.Reconnecting : ConnectionStatus.Connecting;

    public void Finish(Guid id) => _activity.Remove(id);

    public void Connected(Guid id) => _issues.Remove(id);

    public void CompleteConnection(Guid id, bool isActive)
    {
        if (isActive) Connected(id);
        else Lost(id);
    }

    public void Disconnected(Guid id) => _issues.Remove(id);

    public void Lost(Guid id) => _issues[id] = "Connection lost";

    /// Every failure is recorded; only user actions produce an alert (the returned message).
    public string? Failed(Guid id, string message, bool automatic)
    {
        _issues[id] = message;
        return automatic ? null : message;
    }

    public ConnectionStatus? Status(Guid id) =>
        _activity.TryGetValue(id, out var status) ? status
        : _issues.ContainsKey(id) ? ConnectionStatus.ConnectionLost : null;

    public ConnectionStatus TrayStatus(bool hasActiveTunnels)
    {
        if (_activity.ContainsValue(ConnectionStatus.Reconnecting)) return ConnectionStatus.Reconnecting;
        if (_activity.Count > 0) return ConnectionStatus.Connecting;
        if (_issues.Count > 0) return ConnectionStatus.ConnectionLost;
        return hasActiveTunnels ? ConnectionStatus.Connected : ConnectionStatus.Idle;
    }

    public void Retain(IReadOnlySet<Guid> ids)
    {
        foreach (var id in _activity.Keys.Where(k => !ids.Contains(k)).ToList()) _activity.Remove(id);
        foreach (var id in _issues.Keys.Where(k => !ids.Contains(k)).ToList()) _issues.Remove(id);
    }

    public void Reset()
    {
        _activity.Clear();
        _issues.Clear();
    }
}

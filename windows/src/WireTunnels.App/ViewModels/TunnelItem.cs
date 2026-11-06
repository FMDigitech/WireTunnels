using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using WireTunnels.Client;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;

namespace WireTunnels.App.ViewModels;

/// One tunnel as the views see it; updated in place on every state change so bindings,
/// selection and scroll position survive the 2 s status poll.
public sealed partial class TunnelItem(Guid id) : ObservableObject
{
    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];
    private static Brush Secondary => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

    public Guid Id { get; } = id;

    [ObservableProperty] private string _name = "";
    [ObservableProperty] private bool _isActive;
    [ObservableProperty] private bool _isFavorite;
    [ObservableProperty] private bool _isShared;
    [ObservableProperty] private bool _hasWarning;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private bool _canToggle;
    [ObservableProperty] private string _toggleHint = "";
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private Brush? _statusBrush;
    [ObservableProperty] private string _endpoint = "";
    [ObservableProperty] private string _allowedIPs = "";
    [ObservableProperty] private string _allowedIPsList = "";
    [ObservableProperty] private string _address = "";
    [ObservableProperty] private string _dnsServers = "";
    [ObservableProperty] private string _searchDomains = "";
    [ObservableProperty] private string _publicKey = "";
    [ObservableProperty] private string _interfaceName = "";
    [ObservableProperty] private string _infoLine = "";
    [ObservableProperty] private string _connectedFor = "";
    [ObservableProperty] private string _handshake = "";
    [ObservableProperty] private string _received = "";
    [ObservableProperty] private string _sent = "";
    [ObservableProperty] private string _rxRate = "";
    [ObservableProperty] private string _txRate = "";
    [ObservableProperty] private IReadOnlyList<double> _rxSamples = [];
    [ObservableProperty] private IReadOnlyList<double> _txSamples = [];
    [ObservableProperty] private IReadOnlyList<double> _totalSamples = [];
    [ObservableProperty] private bool _hasTraffic;
    [ObservableProperty] private string _configPath = "";
    [ObservableProperty] private string _created = "";
    [ObservableProperty] private string _updated = "";
    [ObservableProperty] private string? _speedTestUrl;
    [ObservableProperty] private string? _feedbackText;
    [ObservableProperty] private bool _isConnectionLost;

    public bool HasFeedback => FeedbackText is not null;
    public bool HasEndpoint => Endpoint.Length > 0;
    public bool HasAllowedIPs => AllowedIPs.Length > 0;
    public bool HasInfoLine => InfoLine.Length > 0;
    public bool HasDnsServers => DnsServers.Length > 0;
    public bool HasSearchDomains => SearchDomains.Length > 0;
    public bool HasPublicKey => PublicKey.Length > 0;
    public bool HasInterface => InterfaceName.Length > 0;
    public bool HasConnectedFor => ConnectedFor.Length > 0;
    public bool IsPersonal => !IsShared;
    public bool CanDelete => !IsActive && !IsBusy;
    public string FavoriteGlyph => IsFavorite ? "" : "";
    public string FavoriteLabel => IsFavorite ? "Remove Favorite" : "Add Favorite";
    public string StatusGlyph => IsActive ? "" : "";
    /// macOS: arrows while (re)connecting, an exclamation mark when the connection was lost.
    public string FeedbackGlyph => IsConnectionLost ? "" : "";
    public Brush FeedbackBrush => Resource(IsConnectionLost ? "ErrorBrush" : "WarningBrush");
    partial void OnIsConnectionLostChanged(bool value)
    {
        OnPropertyChanged(nameof(FeedbackGlyph));
        OnPropertyChanged(nameof(FeedbackBrush));
    }

    /// What screen readers announce for the list row (ListView uses ToString for the item name).
    public override string ToString() => $"{Name}, {StatusText}";

    public void Update(Tunnel t, TunnelManager m, IReadOnlySet<string> warned)
    {
        var now = m.Now;
        var feedback = m.ConnectionStatusOf(t.Id);
        var busy = m.IsBusy(t.Id) || feedback is ConnectionStatus.Connecting or ConnectionStatus.Reconnecting;
        var managedLock = t.Scope == TunnelScope.Managed
            && (t.IsActive ? t.ManagedPolicy?.UsersCanDisconnect == false : t.ManagedPolicy?.UsersCanConnect == false);

        Name = t.Name;
        IsActive = t.IsActive;
        IsFavorite = t.IsFavorite;
        IsShared = t.Scope == TunnelScope.Managed;
        HasWarning = warned.Contains(t.Name);
        IsBusy = busy;
        CanToggle = !busy && !m.IsShuttingDown && !managedLock && (t.IsActive || m.CanConnectTunnels);
        ToggleHint = t.IsActive ? $"Disconnect {t.Name}" : m.ConnectionUnavailableReason ?? $"Connect {t.Name}";
        StatusText = feedback switch
        {
            ConnectionStatus.Connecting => "Connecting…",
            ConnectionStatus.Reconnecting => "Reconnecting…",
            _ when HasWarning => "Warning",
            _ => t.IsActive ? "Connected" : "Disconnected",
        };
        StatusBrush = busy || HasWarning ? Resource("WarningBrush") : t.IsActive ? Resource("ConnectedBrush") : Secondary;

        Endpoint = t.Endpoint ?? "";
        AllowedIPs = string.Join(", ", t.AllowedIPs);
        AllowedIPsList = string.Join("\n", t.AllowedIPs.Take(20)) + (t.AllowedIPs.Count > 20 ? $"\n… {t.AllowedIPs.Count} total prefixes" : "");
        Address = string.Join(", ", t.Address ?? []);
        DnsServers = string.Join(", ", WireGuardDns.Servers(t.Dns));
        SearchDomains = string.Join(", ", WireGuardDns.SearchDomains(t.Dns));
        PublicKey = t.PublicKey ?? "";
        InterfaceName = t.IsActive ? t.InterfaceName ?? "" : "";
        ConnectedFor = t.ConnectedAt is { } since && t.IsActive ? Formatting.Duration(since, now) : "";
        InfoLine = string.Join(" · ", new[]
        {
            t.Address?.FirstOrDefault(), Formatting.Networks(t.AllowedIPs), ConnectedFor.Length > 0 ? $"⏱ {ConnectedFor}" : null,
        }.Where(p => !string.IsNullOrEmpty(p)));
        Handshake = Formatting.Handshake(t.LastHandshake, now);
        Received = Formatting.Bytes(t.RxBytes);
        Sent = Formatting.Bytes(t.TxBytes);

        var samples = m.TrafficOf(t.Id);
        HasTraffic = t.IsActive && samples.Count > 0;
        RxSamples = samples.Select(s => s.RxRate).ToList();
        TxSamples = samples.Select(s => s.TxRate).ToList();
        TotalSamples = samples.Select(s => s.RxRate + s.TxRate).ToList();
        RxRate = Formatting.Rate(samples.Count > 0 ? samples[^1].RxRate : 0);
        TxRate = Formatting.Rate(samples.Count > 0 ? samples[^1].TxRate : 0);

        ConfigPath = t.ConfigPath;
        Created = t.CreatedAt.ToLocalTime().ToString("g");
        Updated = t.UpdatedAt.ToLocalTime().ToString("g");
        SpeedTestUrl = t.SpeedTestURL;
        FeedbackText = feedback is { } f ? ConnectionStatusText.Describe(f) : null;
        IsConnectionLost = feedback == ConnectionStatus.ConnectionLost;
    }

    partial void OnFeedbackTextChanged(string? value) => OnPropertyChanged(nameof(HasFeedback));
    partial void OnEndpointChanged(string value) => OnPropertyChanged(nameof(HasEndpoint));
    partial void OnAllowedIPsChanged(string value) => OnPropertyChanged(nameof(HasAllowedIPs));
    partial void OnInfoLineChanged(string value) => OnPropertyChanged(nameof(HasInfoLine));
    partial void OnDnsServersChanged(string value) => OnPropertyChanged(nameof(HasDnsServers));
    partial void OnSearchDomainsChanged(string value) => OnPropertyChanged(nameof(HasSearchDomains));
    partial void OnPublicKeyChanged(string value) => OnPropertyChanged(nameof(HasPublicKey));
    partial void OnInterfaceNameChanged(string value) => OnPropertyChanged(nameof(HasInterface));
    partial void OnConnectedForChanged(string value) => OnPropertyChanged(nameof(HasConnectedFor));
    partial void OnIsSharedChanged(bool value) => OnPropertyChanged(nameof(IsPersonal));
    partial void OnIsActiveChanged(bool value)
    {
        OnPropertyChanged(nameof(CanDelete));
        OnPropertyChanged(nameof(StatusGlyph));
    }
    partial void OnIsBusyChanged(bool value) => OnPropertyChanged(nameof(CanDelete));
    partial void OnIsFavoriteChanged(bool value)
    {
        OnPropertyChanged(nameof(FavoriteGlyph));
        OnPropertyChanged(nameof(FavoriteLabel));
    }
}

public sealed record WarningItem(string Title, string Message);

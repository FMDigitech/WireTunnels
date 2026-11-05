using System.Text.Json.Serialization;
using WireTunnels.Core.Net;

namespace WireTunnels.Core.Models;

public enum AutoConnectInterface { Ethernet, Wifi, Both }

/// One half of an on-demand rule ("connect on" or "disconnect on").
public sealed class AutoConnectNetworkMatch
{
    public bool Enabled { get; set; }
    public AutoConnectInterface Interface { get; set; } = AutoConnectInterface.Wifi;
    /// Empty = any Wi-Fi network; otherwise only the listed SSIDs.
    public List<string> WifiSSIDs { get; set; } = [];
    /// Empty = any Ethernet network; otherwise only the listed IP subnets.
    public List<string> EthernetSubnets { get; set; } = [];

    public bool Matches(bool isOnEthernet, IReadOnlyCollection<string> ethernetAddresses, bool isOnWiFi, string? currentSSID)
    {
        if (!Enabled) return false;
        var ethernet = isOnEthernet && Interface != AutoConnectInterface.Wifi
            && (EthernetSubnets.Count == 0 || EthernetSubnets.Any(text =>
                IPPrefix.TryParse(text, out var subnet) && text.Contains('/')
                && ethernetAddresses.Any(subnet.ContainsAddress)));
        var wifi = isOnWiFi && Interface != AutoConnectInterface.Ethernet
            && (WifiSSIDs.Count == 0 || (currentSSID is not null && WifiSSIDs.Contains(currentSSID)));
        return ethernet || wifi;
    }
}

/// shortcut: the legacy flat macOS shape (enabled/interface/action) is not decoded; add a converter
/// if metadata from macOS < 1.0.x ever needs importing.
public sealed class AutoConnectRule
{
    public AutoConnectNetworkMatch Connect { get; set; } = new();
    public AutoConnectNetworkMatch Disconnect { get; set; } = new();

    [JsonIgnore]
    public bool Enabled => Connect.Enabled || Disconnect.Enabled;
}

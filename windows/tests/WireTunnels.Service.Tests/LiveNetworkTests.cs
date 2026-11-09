using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using WireTunnels.Core.Net;
using WireTunnels.Service.Native;
using WireTunnels.Service.Network;

#pragma warning disable CA1416 // these run only on Windows, see Live

namespace WireTunnels.Service.Tests;

/// Exercises the real WFP, routing table, NRPT and registry on this PC with harmless values only
/// (TEST-NET addresses, a dynamic WFP session, an .invalid domain). Opt-in: an elevated prompt with
/// WIRETUNNELS_LIVE_TESTS=1. Without it every test returns at once.
public class LiveNetworkTests
{
    private static bool Live => OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("WIRETUNNELS_LIVE_TESTS") == "1";

    /// A blocked connect fails at once with AccessDenied; TEST-NET never answers, so an allowed one times out.
    private static SocketError Connect(string address, int port)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            return socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(address), port)).Wait(1500) ? SocketError.Success : SocketError.TimedOut;
        }
        catch (AggregateException e) when (e.InnerException is SocketException s) { return s.SocketErrorCode; }
    }

    [Fact]
    public void WfpFiltersAreAcceptedAndBlockExactlyWhatTheySay()
    {
        if (!Live) return;
        var engine = Wfp.Open(dynamic: true);
        try
        {
            Wfp.EnsureProviderAndSubLayer(engine);
            WfpFilter[] filters =
            [
                new("live: block TCP to TEST-NET-1 port 9", WfpLayer.ConnectV4, 1, false,
                    [new(WfpField.Protocol, 6), new(WfpField.RemoteAddress, Address: IPAddress.Parse("192.0.2.1")), new(WfpField.RemotePort, 9)]),
                new("live: permit loopback", WfpLayer.ConnectV4, 2, true, [new(WfpField.Flags, FirewallRules.FlagIsLoopback)]),
                new("live: permit interface", WfpLayer.RecvAcceptV6, 2, true, [new(WfpField.LocalInterface, 1)]),
                new("live: permit v6 address", WfpLayer.ConnectV6, 2, true,
                    [new(WfpField.RemoteAddress, Address: IPAddress.Parse("2001:db8::1")), new(WfpField.RemotePort, 9)]),
                new("live: permit ndp", WfpLayer.RecvAcceptV6, 2, true,
                    [new(WfpField.Protocol, 58), new(WfpField.IcmpType, 135), new(WfpField.IcmpType, 136)]),
                new("live: permit dhcp", WfpLayer.ConnectV4, 2, true,
                    [new(WfpField.Protocol, 17), new(WfpField.LocalPort, 68), new(WfpField.RemotePort, 67)]),
            ];
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.1", 9));
            Wfp.Transaction(engine, () => { foreach (var f in filters) Wfp.Add(engine, f, persistent: false); });
            Assert.Equal(filters.Length, Wfp.OurFilters(engine, persistent: false).Count);

            Assert.Equal(SocketError.AccessDenied, Connect("192.0.2.1", 9)); // address in host order, port matched
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.1", 10));
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.2", 9));

            Wfp.Transaction(engine, () => { foreach (var id in Wfp.OurFilters(engine, persistent: false)) Wfp.Delete(engine, id); });
            Assert.Empty(Wfp.OurFilters(engine, persistent: false));
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.1", 9));
        }
        finally { Wfp.Close(engine); }
    }

    /// The real kill switch and DNS guard rule sets, in a dynamic session so a crash cannot leave them behind.
    /// Blocks this PC's traffic for about a second.
    [Fact]
    public void KillSwitchAndDnsGuardBlockWhatTheyShould()
    {
        if (!Live) return;
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var loopbackPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        var engine = Wfp.Open(dynamic: true);
        try
        {
            Wfp.EnsureProviderAndSubLayer(engine);
            void Apply(IReadOnlyList<WfpFilter> filters) => Wfp.Transaction(engine, () =>
            {
                foreach (var id in Wfp.OurFilters(engine, persistent: false)) Wfp.Delete(engine, id);
                foreach (var f in filters) Wfp.Add(engine, f, persistent: false);
            });

            Apply(FirewallRules.DnsGuards([new DnsGuard([IPAddress.Parse("192.0.2.53")])]));
            var dnsElsewhere = Connect("8.8.8.8", 53);
            var https = Connect("1.1.1.1", 443);
            Apply([]);
            Assert.Equal(SocketError.AccessDenied, dnsElsewhere);
            Assert.Equal(SocketError.Success, https);

            Apply(FirewallRules.KillSwitch([new KillSwitchRule(null, IPAddress.Parse("192.0.2.10"), 51820)]));
            var blocked = Connect("1.1.1.1", 443);
            var loopback = Connect("127.0.0.1", loopbackPort);
            Apply([]);
            Assert.Equal(SocketError.AccessDenied, blocked);
            Assert.Equal(SocketError.Success, loopback);
            Assert.Equal(SocketError.Success, Connect("1.1.1.1", 443));
        }
        finally { Wfp.Close(engine); }
    }

    /// The inventory guard: prefix masks for both families and "not this adapter", in a dynamic session.
    [Fact]
    public void InventoryGuardBlocksItsPrefixesOutsideTheTunnel()
    {
        if (!Live) return;
        var engine = Wfp.Open(dynamic: true);
        try
        {
            Wfp.EnsureProviderAndSubLayer(engine);
            var filters = FirewallRules.Inventory([new InventoryGuard(
                [IPPrefix.Parse("192.0.2.0/25"), IPPrefix.Parse("2001:db8::/32")], AllowedLuid: 0x1234_5678, // an adapter that does not exist
                new IPEndPoint(IPAddress.Parse("192.0.2.9"), 51820))]);
            Wfp.Transaction(engine, () => { foreach (var f in filters) Wfp.Add(engine, f, Wfp.InventoryProviderKey, persistent: false); });
            Assert.Equal(filters.Count, Wfp.OurFilters(engine, Wfp.InventoryProviderKey, persistent: false).Count);
            Assert.Empty(Wfp.OurFilters(engine, Wfp.ProviderKey, persistent: false)); // a separate set

            var inside = Connect("192.0.2.5", 9);
            var outside = Connect("192.0.2.200", 9);
            var endpointTcp = Connect("192.0.2.9", 51820); // the endpoint exception is UDP only
            Wfp.Transaction(engine, () => { foreach (var id in Wfp.OurFilters(engine, Wfp.InventoryProviderKey, persistent: false)) Wfp.Delete(engine, id); });
            Assert.Equal(SocketError.AccessDenied, inside);
            Assert.Equal(SocketError.TimedOut, outside);
            Assert.Equal(SocketError.AccessDenied, endpointTcp);
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.5", 9));
        }
        finally { Wfp.Close(engine); }
    }

    [Fact]
    public void PersistentFiltersAreFoundAndRemoved()
    {
        if (!Live) return;
        var engine = Wfp.Open(dynamic: false);
        try
        {
            Wfp.EnsureProviderAndSubLayer(engine);
            var before = Wfp.OurFilters(engine, persistent: true);
            Wfp.Add(engine, new("live: persistent block TEST-NET-1", WfpLayer.ConnectV4, 1, false,
                [new(WfpField.RemoteAddress, Address: IPAddress.Parse("192.0.2.3"))]), persistent: true);
            var added = Wfp.OurFilters(engine, persistent: true).Except(before).ToList();
            try
            {
                Assert.Single(added);
                Assert.Equal(SocketError.AccessDenied, Connect("192.0.2.3", 9));
            }
            finally { foreach (var id in added) Wfp.Delete(engine, id); }
            Assert.Equal(SocketError.TimedOut, Connect("192.0.2.3", 9));
        }
        finally { Wfp.Close(engine); }
    }

    [Fact]
    public void GatewayRoutesAreAddedAndRemoved()
    {
        if (!Live) return;
        var table = new WindowsRouteTable();
        var prefix = IPPrefix.Parse("192.0.2.128/25");
        var route = table.Add(prefix, null, new HashSet<ulong>());
        try
        {
            Assert.NotNull(route.NextHop);
            Assert.Contains(route.NextHop, PowerShell("Get-NetRoute -DestinationPrefix 192.0.2.128/25 -ErrorAction SilentlyContinue | % NextHop"));
            table.Add(prefix, null, new HashSet<ulong>()); // already present is fine
        }
        finally
        {
            table.Delete(route);
            table.Delete(route); // already gone is fine
        }
        Assert.DoesNotContain("192.0.2", PowerShell("Get-NetRoute -DestinationPrefix 192.0.2.128/25 -ErrorAction SilentlyContinue | % DestinationPrefix"));
    }

    [Fact]
    public void NrptRulesReachTheDnsClient()
    {
        if (!Live) return;
        var store = new RegistryNrptStore();
        const string Domain = "wiretunnels-live-test.invalid";
        const string Sid = "S-1-5-21-0-0-0-1";
        try
        {
            Assert.Empty(SplitDns.Sync(store, Sid, new Dictionary<string, IReadOnlyList<string>> { [Domain] = ["192.0.2.53"] }));
            Assert.Contains("192.0.2.53", PowerShell($"Get-DnsClientNrptPolicy | ? Namespace -eq '.{Domain}' | % NameServers"));
        }
        finally { SplitDns.Sync(store, Sid, new Dictionary<string, IReadOnlyList<string>>()); }
        Assert.DoesNotContain("192.0.2.53", PowerShell($"Get-DnsClientNrptPolicy | ? Namespace -eq '.{Domain}' | % NameServers"));
    }

    [Fact]
    public void VolatileJournalRoundTrips()
    {
        if (!Live) return;
        var journal = new VolatileRegistryJournal();
        var previous = journal.Load();
        try
        {
            journal.Save("""{"live":true}""");
            Assert.Equal("""{"live":true}""", journal.Load());
            Assert.Contains("True", PowerShell(@"[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\WireTunnels\Runtime') -ne $null"));
        }
        finally { journal.Save(previous); }
    }

    private static string PowerShell(string command)
    {
        var info = new ProcessStartInfo("powershell.exe", ["-NoProfile", "-Command", command]) { RedirectStandardOutput = true };
        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return output;
    }
}

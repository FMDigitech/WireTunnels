using WireTunnels.Core.Config;

namespace WireTunnels.Client.Tests;

public class ConfigStoreTests : IDisposable
{
    private readonly Harness _h = new();
    public void Dispose() => _h.Dispose();

    [Fact]
    public void OnlyFilesInsideTheStoreAreReadOrDeleted()
    {
        var outside = Path.Combine(_h.Root, "outside.conf.dpapi");
        Directory.CreateDirectory(_h.Root);
        File.WriteAllText(outside, "keep me");

        Assert.Null(_h.Configs.AliasOf(outside));
        Assert.Throws<InvalidDataException>(() => _h.Configs.Read(outside));
        _h.Configs.Delete(outside);
        Assert.True(File.Exists(outside));
        Assert.Null(_h.Configs.AliasOf(Path.Combine(_h.Configs.Directory, "..", "x.conf.dpapi")));
    }

    [Fact]
    public void ConfigsOfAnotherUserReportAClearError()
    {
        var path = _h.Configs.Save("office", Harness.Config());
        File.WriteAllBytes(path, [1, 2, 3]);
        Assert.Contains("another Windows user", Assert.Throws<InvalidDataException>(() => _h.Configs.Read(path)).Message);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("bad\u0007name")]
    public void InvalidDisplayNamesAreRefused(string name) =>
        Assert.Throws<ConfigStorageException>(() => _h.Configs.Save(name, Harness.Config()));

    [Fact]
    public void OversizedSourceFilesAreRefused()
    {
        Directory.CreateDirectory(_h.Root);
        var big = Path.Combine(_h.Root, "big.conf");
        File.WriteAllBytes(big, new byte[ConfigStore.MaxConfigBytes + 1]);
        Assert.Throws<InvalidDataException>(() => ConfigStore.ReadSource(big));
    }
}

public class LogServiceTests : IDisposable
{
    private readonly Harness _h = new();
    public void Dispose() => _h.Dispose();

    [Fact]
    public void KeysNeverReachTheLog()
    {
        var key = WireGuardKey.Generate().PrivateKey;
        _h.Log.Error($"bad line PrivateKey = {key} and PresharedKey={key}");
        _h.Log.Info($"key {key} leaked");
        var file = File.ReadAllText(_h.Log.FilePath);
        Assert.DoesNotContain(key, file);
        Assert.Contains("PrivateKey = (hidden)", file);
        Assert.All(_h.Log.Entries, e => Assert.DoesNotContain(key, e));
        Assert.Contains("[ERROR]", _h.Log.Entries[0]);
    }

    [Fact]
    public void ClearRemovesEntriesAndTheFile()
    {
        _h.Log.Info("hello");
        _h.Log.Clear();
        Assert.Empty(_h.Log.Entries);
        Assert.False(File.Exists(_h.Log.FilePath));
    }
}

public class FormTests
{
    [Fact]
    public void BasicFormRoundTripsAConfig()
    {
        var (priv, _) = WireGuardKey.Generate();
        var peer = WireGuardKey.Generate().PublicKey;
        var form = new BasicConfigForm
        {
            PrivateKey = priv, Address = "10.0.0.2/32", Dns = "1.1.1.1", SearchDomains = "Corp.Example, lan",
            PeerPublicKey = peer, Endpoint = "vpn.example.com:51820", AllowedIPs = "10.0.0.0/24", PersistentKeepalive = "25",
        };
        var config = WireGuardConfig.Parse(form.ToConfig());
        Assert.True(config.IsValid, string.Join("; ", config.Errors.Select(e => e.Message)));
        Assert.Equal(["1.1.1.1", "corp.example", "lan"], config.Dns);
        Assert.Equal(25, config.PrimaryPeer!.PersistentKeepalive);

        var back = BasicConfigForm.From(form.ToConfig());
        Assert.Equal("1.1.1.1", back.Dns);
        Assert.Equal("corp.example, lan", back.SearchDomains);
        Assert.Equal(peer, back.PeerPublicKey);
    }

    [Fact]
    public void InvalidSearchDomainsBlockSaving()
    {
        var form = new BasicConfigForm { PrivateKey = "x", Address = "10.0.0.2/32", SearchDomains = "-bad-" };
        Assert.Equal(["-bad-"], form.InvalidSearchDomains);
        Assert.False(form.CanSave);
    }

    [Fact]
    public void TemplatesParseLikeOnMacOS()
    {
        Assert.Equal(["Empty", "Split Tunnel", "Full Tunnel"], ConfigTemplate.All.Select(t => t.Name));
        var full = WireGuardConfig.Parse(ConfigTemplate.All[2].Content);
        Assert.Equal(["0.0.0.0/0", "::/0"], full.PrimaryPeer!.AllowedIPs);
    }
}

public class FormattingTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 6, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(512, "512 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(5 * 1048576, "5.00 MB")]
    [InlineData(3L * 1073741824, "3.00 GB")]
    public void Bytes(long value, string expected) => Assert.Equal(expected, Formatting.Bytes(value));

    [Fact]
    public void DurationsAndHandshakes()
    {
        Assert.Equal("45s", Formatting.Duration(Now.AddSeconds(-45), Now));
        Assert.Equal("2m 5s", Formatting.Duration(Now.AddSeconds(-125), Now));
        Assert.Equal("3h 1m", Formatting.Duration(Now.AddMinutes(-181), Now));
        Assert.Equal("Never", Formatting.Handshake(null, Now));
        Assert.Equal("1 second ago", Formatting.Handshake(Now.AddSeconds(-1), Now));
        Assert.Equal("5 minutes ago", Formatting.Handshake(Now.AddMinutes(-5), Now));
    }

    [Fact]
    public void NetworksSummary()
    {
        Assert.Equal("", Formatting.Networks([]));
        Assert.Equal("10.0.0.0/24, 10.1.0.0/24", Formatting.Networks(["10.0.0.0/24", "10.1.0.0/24"]));
        Assert.Equal("10.0.0.0/24 +2 more", Formatting.Networks(["10.0.0.0/24", "a", "b"]));
    }
}

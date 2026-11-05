using WireTunnels.Core.Config;

namespace WireTunnels.Core.Tests;

public class ConfigNameTests
{
    // Expected values produced by the macOS WireTunnelsHelper/ConfigName.swift, so aliases match across platforms.
    [Theory]
    [InlineData("Office VPN", "Office_V-8d9559")]
    [InlineData("Office_VPN", "Office_VPN")]
    [InlineData("東京 VPN 🔒", "___VPN__-26ae3a")]
    [InlineData("VPN 👩‍💻", "VPN____-663c59")]
    [InlineData("vpn.example", "vpn.example")]
    [InlineData("vpn.conf", "vpn")]
    [InlineData(".conf", "tunnel-97f30b")]
    [InlineData("vpn.", "vpn.-4edc33")]
    [InlineData(".", ".-0c98f1")]
    [InlineData("../Office/VPN", "___Offic-a5dcc1")]
    [InlineData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaa-394ba7")]
    [InlineData("Café", "Caf_-c290a9")]
    [InlineData("abcdefghijklmno", "abcdefghijklmno")]
    [InlineData("abcdefghijklmnop", "abcdefgh-8bb1f5")]
    public void AliasMatchesMacOS(string name, string expected)
    {
        var alias = ConfigName.FileBaseName(name);
        Assert.Equal(expected, alias);
        Assert.True(ConfigName.IsValidAlias(alias));
    }

    [Fact]
    public void EquivalentUnicodeNamesShareAlias() =>
        Assert.Equal(ConfigName.FileBaseName("Café"), ConfigName.FileBaseName("Café"));

    [Fact]
    public void DisplayNameIsTrimmedAndCapped()
    {
        Assert.Equal("Office VPN", ConfigName.DisplayName("  Office VPN  \n"));
        Assert.Equal(50, ConfigName.DisplayName(new string('a', 80)).Length);
    }

    [Theory]
    [InlineData("")]
    [InlineData("a..b")]
    [InlineData("abcdefghijklmnop")]
    [InlineData("bad/name")]
    public void InvalidAliasesAreRejected(string alias) => Assert.False(ConfigName.IsValidAlias(alias));
}

public class ConfigSafetyTests
{
    [Theory]
    [InlineData("[Interface]\nPostUp = calc.exe", "postup")]
    [InlineData("[Interface]\n  preup=x", "preup")]
    [InlineData("[Interface]\nPreDown", "predown")]
    [InlineData("[Interface]\nPOSTDOWN = x # c", "postdown")]
    public void HooksAreRejected(string text, string hook) =>
        Assert.Equal(new ConfigViolation(ConfigViolationKind.Hook, hook), ConfigSafety.FirstViolation(text));

    [Theory]
    [InlineData("[Interface]\nAddress = 10.0.0.1/32\u0000")]
    [InlineData("[Interface]\rPostUp = x")]
    [InlineData("a\u2028b")]
    [InlineData("a\u0085b")]
    public void ControlCharactersAreRejected(string text) =>
        Assert.Equal(ConfigViolationKind.ControlCharacter, ConfigSafety.FirstViolation(text)?.Kind);

    [Fact]
    public void CommentedHookAndCrlfAreAllowed() =>
        Assert.Null(ConfigSafety.FirstViolation("[Interface]\r\n# PostUp = x\r\nAddress = 10.0.0.2/32\r\n"));
}

public class WireGuardConfigTests
{
    private static readonly string Priv = WireGuardKey.Generate().PrivateKey;
    private static readonly string Pub = WireGuardKey.Generate().PublicKey;

    private static string Sample(string extraInterface = "", string allowed = "10.0.0.0/24") => $"""
        [Interface]
        PrivateKey = {Priv}
        Address = 10.0.0.2/32, fd00::2/128
        DNS = 10.0.0.1, corp.example
        MTU = 1380
        {extraInterface}

        [Peer]
        PublicKey = {Pub}
        Endpoint = vpn.example.com:51820
        AllowedIPs = {allowed} # office
        PersistentKeepalive = 25

        [Peer]
        PublicKey = {Pub}
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = 192.168.50.0/24
        """;

    [Fact]
    public void ParsesInterfaceAndAllPeers()
    {
        var c = WireGuardConfig.Parse(Sample());
        Assert.True(c.IsValid, string.Join("; ", c.Errors.Select(e => e.Message)));
        Assert.Equal(["10.0.0.2/32", "fd00::2/128"], c.Address);
        Assert.Equal(1380, c.Mtu);
        Assert.Equal(2, c.Peers.Count);
        Assert.Equal(["10.0.0.0/24"], c.Peers[0].AllowedIPs);
        Assert.Equal(25, c.Peers[0].PersistentKeepalive);
        Assert.Equal(new Endpoint("2001:db8::1", 51820), Endpoint.TryParse(c.Peers[1].Endpoint!));
        Assert.DoesNotContain(ConfigWarning.FullTunnel, c.Warnings);
    }

    [Fact]
    public void MissingFieldsAreErrors()
    {
        var c = WireGuardConfig.Parse("[Interface]\n[Peer]\n");
        Assert.Equal(
            [ConfigError.MissingPrivateKey, ConfigError.MissingAddress, ConfigError.MissingPeerPublicKey, ConfigError.MissingAllowedIPs],
            c.Errors.Select(e => e.Error));
        Assert.Contains(ConfigWarning.MissingDns, c.Warnings);
        Assert.Contains(ConfigWarning.MissingEndpoint, c.Warnings);
    }

    [Fact]
    public void HookIsAnError() =>
        Assert.Contains(WireGuardConfig.Parse(Sample("PostUp = calc.exe")).Errors, e => e.Error == ConfigError.UnsupportedDirective);

    [Theory]
    [InlineData("10.0.0.0/33")]
    [InlineData("010.0.0.0/8")]
    [InlineData("10.0.0/8")]
    [InlineData("example.com/32")]
    public void InvalidAllowedIPsAreErrors(string allowed) =>
        Assert.Contains(WireGuardConfig.Parse(Sample(allowed: allowed)).Errors, e => e.Error == ConfigError.InvalidValue);

    [Fact]
    public void FullTunnelWithoutIPv6AddressWarnsAboutLeak()
    {
        var c = WireGuardConfig.Parse(Sample(allowed: "0.0.0.0/0, ::/0").Replace(", fd00::2/128", ""));
        Assert.Contains(ConfigWarning.FullTunnel, c.Warnings);
        Assert.Contains(ConfigWarning.Ipv6RoutedWithoutAddress, c.Warnings);
        Assert.DoesNotContain(ConfigWarning.Ipv4RoutedWithoutAddress, c.Warnings);
    }

    [Theory]
    [InlineData("1.2.3.4:51820", true)]
    [InlineData("vpn.example.com:1", true)]
    [InlineData("[::1]:51820", true)]
    [InlineData("::1:51820", false)]
    [InlineData("vpn.example.com", false)]
    [InlineData("vpn.example.com:0", false)]
    [InlineData("vpn.example.com:65536", false)]
    [InlineData("bad host:1", false)]
    public void EndpointParsing(string text, bool valid) => Assert.Equal(valid, Endpoint.TryParse(text) is not null);
}

public class WireGuardDnsTests
{
    [Fact]
    public void SplitsServersAndSearchDomains()
    {
        string[] entries = ["10.0.0.1", "fd00::1", "corp.example"];
        Assert.Equal(["10.0.0.1", "fd00::1"], WireGuardDns.Servers(entries));
        Assert.Equal(["corp.example"], WireGuardDns.SearchDomains(entries));
    }

    [Theory]
    [InlineData("*.Corp.Example.", "corp.example")]
    [InlineData("..a-b.c", "a-b.c")]
    [InlineData("-bad.com", null)]
    [InlineData("bad_.com", null)]
    [InlineData("a..b", null)]
    [InlineData("", null)]
    public void NormalizesDomains(string raw, string? expected) => Assert.Equal(expected, WireGuardDns.NormalizedDomain(raw));

    [Fact]
    public void ComposeReportsInvalidDomains()
    {
        var (line, invalid) = WireGuardDns.Compose("10.0.0.1, 10.0.0.2", "corp.example CORP.example bad_domain");
        Assert.Equal("10.0.0.1, 10.0.0.2, corp.example", line);
        Assert.Equal(["bad_domain"], invalid);
    }
}

public class WireGuardKeyTests
{
    [Fact]
    public void DerivesRfc7748PublicKey()
    {
        // RFC 7748 section 6.1, Alice.
        var priv = Convert.ToBase64String(Convert.FromHexString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"));
        var pub = Convert.ToBase64String(Convert.FromHexString("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"));
        Assert.Equal(pub, WireGuardKey.PublicKey(priv));
    }

    [Fact]
    public void GeneratedPairIsConsistent()
    {
        var (priv, pub) = WireGuardKey.Generate();
        Assert.Equal(pub, WireGuardKey.PublicKey(priv));
        Assert.NotEqual(WireGuardKey.Generate().PrivateKey, priv);
    }

    [Theory]
    [InlineData("not base64")]
    [InlineData("AAAA")]
    public void RejectsNonKeys(string value) => Assert.Null(WireGuardKey.PublicKey(value));
}

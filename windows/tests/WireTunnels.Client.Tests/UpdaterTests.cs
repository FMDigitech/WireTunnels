using System.Net;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace WireTunnels.Client.Tests;

public class UpdaterTests
{
    private static string Item(string version, string os, string url = "https://example.com/WireTunnels-{v}.msi", string sig = "AAAA") =>
        $"""
        <item><title>Version {version}</title><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
        <enclosure url="{url.Replace("{v}", version)}" length="4" type="application/octet-stream" sparkle:os="{os}" sparkle:edSignature="{sig}"/></item>
        """;

    private static string Feed(params string[] items) =>
        $"""<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{string.Concat(items)}</channel></rss>""";

    [Fact]
    public void PicksNewestItemForThisOsOnly()
    {
        var xml = Feed(Item("1.1.0", "windows-x64"), Item("1.3.0", "windows-arm64"), Item("1.2.0", "windows-x64"), Item("1.0.0", "windows-x64"));
        Assert.Equal(new Version(1, 2, 0), Appcast.Newest(xml, "windows-x64", new Version(1, 0, 0))!.Version);
        Assert.Null(Appcast.Newest(xml, "windows-x64", new Version(1, 2, 0)));
    }

    [Fact]
    public void IgnoresUntrustedItems()
    {
        var xml = Feed(Item("2.0.0", "windows-x64", url: "http://example.com/a.msi"), Item("2.0.0", "windows-x64", sig: ""));
        Assert.Null(Appcast.Newest(xml, "windows-x64", new Version(1, 0, 0)));
        Assert.Null(Appcast.Newest("not xml", "windows-x64", new Version(1, 0, 0)));
    }

    private static (string publicKey, string signature) Sign(byte[] data)
    {
        var seed = new byte[32];
        new Random(7).NextBytes(seed);
        var key = new Ed25519PrivateKeyParameters(seed);
        var signer = new Ed25519Signer();
        signer.Init(true, key);
        signer.BlockUpdate(data, 0, data.Length);
        return (Convert.ToBase64String(key.GeneratePublicKey().GetEncoded()), Convert.ToBase64String(signer.GenerateSignature()));
    }

    [Fact]
    public void Ed25519RejectsTamperedDataAndGarbage()
    {
        var data = Encoding.UTF8.GetBytes("installer");
        var (key, signature) = Sign(data);
        Assert.True(Ed25519.Verify(key, signature, new MemoryStream(data)));
        Assert.False(Ed25519.Verify(key, signature, new MemoryStream(Encoding.UTF8.GetBytes("installer!"))));
        Assert.False(Ed25519.Verify(key, "not base64!", new MemoryStream(data)));
        Assert.False(Ed25519.Verify(key, Convert.ToBase64String(new byte[10]), new MemoryStream(data)));
    }

    private sealed class Handler(byte[] body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) });
    }

    private static async Task<string> Download(byte[] served, byte[] signed, Func<string, string, string?> authenticode, string folder)
    {
        var (key, signature) = Sign(signed);
        var service = new UpdateService(new HttpClient(new Handler(served)), "https://example.com/feed.xml", key, "Pub", authenticode);
        var item = new UpdateItem(new Version(2, 0), "v2", "https://example.com/WireTunnels-2.0.msi", 0, signature, "");
        return await service.DownloadAsync(item, folder);
    }

    [Fact]
    public async Task DownloadKeepsOnlyAFullyVerifiedInstaller()
    {
        var folder = Path.Combine(Path.GetTempPath(), "wt-update-" + Guid.NewGuid());
        try
        {
            var data = Encoding.UTF8.GetBytes("installer");
            var path = await Download(data, data, (_, _) => null, folder);
            Assert.True(File.Exists(path));

            File.Delete(path);
            await Assert.ThrowsAsync<InvalidOperationException>(() => Download(Encoding.UTF8.GetBytes("evil"), data, (_, _) => null, folder));
            Assert.False(File.Exists(path));
            await Assert.ThrowsAsync<InvalidOperationException>(() => Download(data, data, (_, _) => "wrong publisher", folder));
            Assert.False(File.Exists(path));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
}

public class UpdateHandoffTests
{
    [Fact]
    public void ReleaseNotesBecomePlainBullets()
    {
        var item = new UpdateItem(new Version(1, 1), "v", "https://e.com/a.msi", 0, "x",
            "<ul><li>New: a &amp; b</li><li>Fix: c</li></ul><p><strong>Notes</strong></p>");
        Assert.Equal("• New: a & b\n• Fix: c\nNotes", item.PlainNotes);
    }

    [Fact]
    public void HandoffRestartsTheAppWhateverMsiexecReturnsAndRefusesUnsafePaths()
    {
        var line = UpdateHandoff.CommandLine(@"C:\t\WireTunnels-1.1.msi", @"C:\u\update-result.txt", @"C:\Program Files\WireTunnels\WireTunnels.App.exe");
        Assert.Contains(@"""msiexec.exe"" /i ""C:\t\WireTunnels-1.1.msi"" /passive", line);
        Assert.Contains(@"&& echo ok>""C:\u\update-result.txt"" || echo fail>", line);
        Assert.EndsWith(@"& explorer.exe ""C:\Program Files\WireTunnels\WireTunnels.App.exe""""", line);
        Assert.Throws<ArgumentException>(() => UpdateHandoff.CommandLine("a\".msi", "r", "e"));
        Assert.Throws<ArgumentException>(() => UpdateHandoff.CommandLine("a.msi", "%TEMP%\r", "e"));
    }

    [Fact]
    public void ResultIsReportedOnce()
    {
        var file = Path.Combine(Path.GetTempPath(), "wt-result-" + Guid.NewGuid());
        Assert.Null(UpdateHandoff.Consume(file));
        File.WriteAllText(file, "fail \r\n");
        Assert.False(UpdateHandoff.Consume(file));
        Assert.Null(UpdateHandoff.Consume(file));
        File.WriteAllText(file, "ok\r\n");
        Assert.True(UpdateHandoff.Consume(file));
    }
}

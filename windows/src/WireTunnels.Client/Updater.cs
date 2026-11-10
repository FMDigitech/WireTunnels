using System.Globalization;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace WireTunnels.Client;

/// One installer offered by the Windows appcast (`appcast-windows.xml`, Sparkle/NetSparkle item format).
public sealed record UpdateItem(Version Version, string Title, string Url, long Length, string EdSignature, string Notes)
{
    /// The release notes without markup, one bullet per line, for a plain TextBlock.
    public string PlainNotes
    {
        get
        {
            var options = System.Text.RegularExpressions.RegexOptions.IgnoreCase;
            var text = System.Text.RegularExpressions.Regex.Replace(Notes, @"<li[^>]*>", "\n• ", options);
            text = System.Text.RegularExpressions.Regex.Replace(text, @"</(p|ul|ol|h\d)>|<br\s*/?>", "\n", options);
            text = System.Net.WebUtility.HtmlDecode(System.Text.RegularExpressions.Regex.Replace(text, "<[^>]+>", ""));
            return string.Join("\n", text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0));
        }
    }
}

/// How an update is handed to Windows Installer, and how the next start learns what happened. The app has to quit
/// before the installer replaces its files, so the elevated command line itself restarts the app (de-elevated, through
/// explorer) once msiexec ends, whether the install succeeded or Windows Installer rolled it back, and records which.
public static class UpdateHandoff
{
    public const string Succeeded = "ok", Failed = "fail";

    /// Arguments for an elevated `cmd.exe`. Every path is ours (temp folder, install folder, app data), never from the feed.
    public static string CommandLine(string msi, string resultFile, string appExe)
    {
        foreach (var path in new[] { msi, resultFile, appExe })
            if (path.Contains('"') || path.Contains('%') || path.Contains('^')) throw new ArgumentException($"Unsupported character in {path}");
        return $"/d /s /c \"\"msiexec.exe\" /i \"{msi}\" /passive /norestart && echo {Succeeded}>\"{resultFile}\" || echo {Failed}>\"{resultFile}\" & explorer.exe \"{appExe}\"\"";
    }

    /// null when no update ran; otherwise whether it installed. The file is removed so it is reported once.
    public static bool? Consume(string resultFile)
    {
        if (!File.Exists(resultFile)) return null;
        string text;
        try { text = File.ReadAllText(resultFile).Trim(); File.Delete(resultFile); }
        catch (IOException) { return null; }
        return text == Succeeded;
    }
}

public static class Appcast
{
    private static readonly XNamespace Sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";

    /// "windows-x64" / "windows-arm64" for this process.
    public static string CurrentOs => "windows-" + (RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64");

    /// The newest item for `os` that is newer than `current`; items without an https URL, a signature or a
    /// parsable version are ignored (a feed is untrusted input).
    public static UpdateItem? Newest(string xml, string os, Version current)
    {
        XDocument doc;
        try { doc = XDocument.Parse(xml); }
        catch (System.Xml.XmlException) { return null; }
        return doc.Descendants("item").Select(item => Parse(item, os))
            .Where(i => i is not null && i.Version > current)
            .OrderByDescending(i => i!.Version).FirstOrDefault();
    }

    private static UpdateItem? Parse(XElement item, string os)
    {
        var enclosure = item.Element("enclosure");
        if (enclosure is null || (string?)enclosure.Attribute(Sparkle + "os") != os) return null;
        var versionText = (string?)item.Element(Sparkle + "shortVersionString") ?? (string?)enclosure.Attribute(Sparkle + "shortVersionString");
        var url = (string?)enclosure.Attribute("url");
        var signature = (string?)enclosure.Attribute(Sparkle + "edSignature");
        if (!Version.TryParse(versionText, out var version) || string.IsNullOrEmpty(signature)
            || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return null;
        _ = long.TryParse((string?)enclosure.Attribute("length"), NumberStyles.None, CultureInfo.InvariantCulture, out var length);
        return new UpdateItem(version, (string?)item.Element("title") ?? $"Version {versionText}", url!, length, signature, (string?)item.Element("description") ?? "");
    }
}

public static class Ed25519
{
    /// Sparkle's `sign_update` format: base64 signature over the raw file bytes; the public key is base64 too.
    public static bool Verify(string publicKeyBase64, string signatureBase64, Stream data)
    {
        try
        {
            var key = Convert.FromBase64String(publicKeyBase64);
            var signature = Convert.FromBase64String(signatureBase64);
            if (key.Length != 32 || signature.Length != 64) return false;
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(key));
            var buffer = new byte[81920];
            int read;
            while ((read = data.Read(buffer, 0, buffer.Length)) > 0) verifier.BlockUpdate(buffer, 0, read);
            return verifier.VerifySignature(signature);
        }
        catch (FormatException) { return false; }
    }
}

/// Checks the Windows appcast, downloads an installer and refuses it unless the Ed25519 signature (same key format as
/// the macOS Sparkle feed) and the Authenticode signature of the publisher both verify. NetSparkle was not used: it has
/// no WinUI 3 UI, and this part is small.
public sealed class UpdateService(HttpClient http, string feedUrl, string publicKey, string publisher, Func<string, string, string?> verifyAuthenticode)
{
    public const string DefaultFeed = "https://raw.githubusercontent.com/FMDigitech/WireTunnels/main/appcast-windows.xml";
    /// Same key as the macOS feed; the private half signs Windows installers too (see windows/installer/README.md).
    public const string DefaultPublicKey = "YFTXWuQkChzuy1Zhc2i2oJX3qunpBrIS7JZTWcZFobw=";
    /// Subject (simple name) of the code-signing certificate of the MSI.
    public const string DefaultPublisher = "FMDigitech";

    public async Task<UpdateItem?> CheckAsync(Version current, CancellationToken ct = default)
    {
        if (!feedUrl.StartsWith("https://", StringComparison.Ordinal)) throw new InvalidOperationException("The update feed must use https");
        var xml = await http.GetStringAsync(feedUrl, ct);
        return Appcast.Newest(xml, Appcast.CurrentOs, current);
    }

    /// Downloads into `folder` and returns the verified MSI path; deletes the file when a check fails.
    public async Task<string> DownloadAsync(UpdateItem item, string folder, CancellationToken ct = default)
    {
        Directory.CreateDirectory(folder);
        if (!new Uri(item.Url).AbsolutePath.EndsWith(".msi", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The update is not an MSI package");
        // A fixed name: the file name in the feed is untrusted and ends up on an elevated command line.
        var path = Path.Combine(folder, $"WireTunnels-{item.Version}.msi");
        try
        {
            await using (var output = File.Create(path))
            {
                using var response = await http.GetAsync(item.Url, HttpCompletionOption.ResponseHeadersRead, ct);
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync(ct);
                await input.CopyToAsync(output, ct);
            }
            using (var file = File.OpenRead(path))
            {
                if (item.Length > 0 && file.Length != item.Length) throw new InvalidOperationException("The downloaded update has the wrong size");
                if (!Ed25519.Verify(publicKey, item.EdSignature, file)) throw new InvalidOperationException("The update's signature is not valid");
            }
            if (verifyAuthenticode(path, publisher) is { } problem) throw new InvalidOperationException(problem);
            return path;
        }
        catch
        {
            try { File.Delete(path); } catch (IOException) { }
            throw;
        }
    }
}

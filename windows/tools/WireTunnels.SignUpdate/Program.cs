using System.Security;
using System.Xml.Linq;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

// signupdate keygen                              new key pair (private seed + public key, base64)
// signupdate sign <file>                         private key from WIRETUNNELS_ED25519_KEY; prints the base64 signature
// signupdate appcast <appcast.xml> <msi> <version> <os> <url> [notes.html]
//                                                signs <msi> and adds an item (creates the feed when missing)
const string KeyVariable = "WIRETUNNELS_ED25519_KEY";
XNamespace sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";

try
{
    switch (args)
    {
        case ["keygen"]:
            var seed = new byte[32];
            System.Security.Cryptography.RandomNumberGenerator.Fill(seed);
            var generated = new Ed25519PrivateKeyParameters(seed);
            Console.WriteLine($"private (keep secret, set as {KeyVariable}): {Convert.ToBase64String(seed)}");
            Console.WriteLine($"public  (UpdateService.DefaultPublicKey):  {Convert.ToBase64String(generated.GeneratePublicKey().GetEncoded())}");
            return 0;
        case ["sign", var file]:
            Console.WriteLine(Sign(file));
            return 0;
        case ["appcast", var feed, var msi, var version, var os, var url, ..]:
            AddItem(feed, msi, version, os, url, args.Length > 6 ? File.ReadAllText(args[6]) : "");
            return 0;
        default:
            Console.Error.WriteLine("usage: signupdate keygen | sign <file> | appcast <appcast.xml> <msi> <version> <windows-x64|windows-arm64> <url> [notes.html]");
            return 2;
    }
}
catch (Exception e) when (e is IOException or FormatException or InvalidOperationException or SecurityException)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}

string Sign(string path)
{
    // Sparkle exports 32 bytes (seed) or 64 (seed + public key): the seed is the first 32 either way.
    var raw = Convert.FromBase64String(Environment.GetEnvironmentVariable(KeyVariable) ?? throw new InvalidOperationException($"{KeyVariable} is not set"));
    if (raw.Length is not (32 or 64)) throw new FormatException($"{KeyVariable} must be a base64 Ed25519 private key");
    var signer = new Ed25519Signer();
    signer.Init(true, new Ed25519PrivateKeyParameters(raw, 0));
    var data = File.ReadAllBytes(path);
    signer.BlockUpdate(data, 0, data.Length);
    return Convert.ToBase64String(signer.GenerateSignature());
}

void AddItem(string feed, string msi, string version, string os, string url, string notes)
{
    var doc = File.Exists(feed) ? XDocument.Load(feed) : new XDocument(new XElement("rss", new XAttribute("version", "2.0"),
        new XAttribute(XNamespace.Xmlns + "sparkle", sparkle.NamespaceName),
        new XElement("channel", new XElement("title", "WireTunnels for Windows Changelog"),
            new XElement("link", "https://github.com/FMDigitech/WireTunnels"),
            new XElement("description", "WireTunnels for Windows update feed"))));
    var channel = doc.Root!.Element("channel")!;
    var item = new XElement("item",
        new XElement("title", $"Version {version}"),
        new XElement("pubDate", DateTime.UtcNow.ToString("R")),
        new XElement(sparkle + "version", version),
        new XElement(sparkle + "shortVersionString", version),
        new XElement(sparkle + "minimumSystemVersion", "10.0.19041"),
        new XElement("description", new XCData(notes)),
        new XElement("enclosure", new XAttribute("url", url), new XAttribute("length", new FileInfo(msi).Length),
            new XAttribute("type", "application/octet-stream"), new XAttribute(sparkle + "os", os),
            new XAttribute(sparkle + "edSignature", Sign(msi))));
    // Newest first, after the channel header.
    channel.Elements("item").FirstOrDefault()?.AddBeforeSelf(item);
    if (item.Parent is null) channel.Add(item);
    doc.Save(feed);
}

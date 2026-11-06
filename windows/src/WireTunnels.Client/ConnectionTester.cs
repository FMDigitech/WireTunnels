using System.Diagnostics;
using System.Globalization;
using System.Net.NetworkInformation;
using WireTunnels.Core.Config;

namespace WireTunnels.Client;

public abstract record ConnectionTestResult
{
    public sealed record Success(double AverageMs, double? ThroughputMbps) : ConnectionTestResult;
    public sealed record Unreachable : ConnectionTestResult;
    public sealed record UnknownEndpoint : ConnectionTestResult;

    public string Describe() => this switch
    {
        Success { ThroughputMbps: { } mbps } s => string.Create(CultureInfo.InvariantCulture, $"{s.AverageMs:0} ms avg, {mbps:0.0} Mbps"),
        Success s => string.Create(CultureInfo.InvariantCulture, $"{s.AverageMs:0} ms avg"),
        Unreachable => "Unreachable",
        _ => "Endpoint unknown",
    };
}

/// Port of PingService + ThroughputProbeService: latency to the tunnel's own peer endpoint
/// (no third-party host), plus a throughput probe only against a URL the user set.
public static class ConnectionTester
{
    private const int MaxProbeBytes = 20 * 1024 * 1024;
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(8);

    public static async Task<ConnectionTestResult> TestAsync(string? endpoint, string? speedTestUrl, CancellationToken ct = default)
    {
        if (endpoint is null || Endpoint.TryParse(endpoint) is not { } parsed) return new ConnectionTestResult.UnknownEndpoint();
        var samples = await PingAsync(parsed.Host, ct);
        if (samples.Count == 0) return new ConnectionTestResult.Unreachable();
        double? mbps = null;
        if (!string.IsNullOrWhiteSpace(speedTestUrl) && Uri.TryCreate(speedTestUrl, UriKind.Absolute, out var url)
            && (url.Scheme == Uri.UriSchemeHttps || url.Scheme == Uri.UriSchemeHttp))
            mbps = await ThroughputAsync(url, ct);
        return new ConnectionTestResult.Success(samples.Average(), mbps);
    }

    private static async Task<List<double>> PingAsync(string host, CancellationToken ct)
    {
        var samples = new List<double>();
        using var ping = new Ping();
        for (var i = 0; i < 3; i++)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var reply = await ping.SendPingAsync(host, 2000);
                if (reply.Status == IPStatus.Success) samples.Add(reply.RoundtripTime);
            }
            catch (PingException) { }
        }
        return samples;
    }

    private static async Task<double?> ThroughputAsync(Uri url, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = ProbeTimeout };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(ProbeTimeout);
        var watch = Stopwatch.StartNew();
        long total = 0;
        try
        {
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode) return null;
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            var buffer = new byte[64 * 1024];
            int read;
            while (total < MaxProbeBytes && (read = await stream.ReadAsync(buffer, timeout.Token)) > 0) total += read;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { /* time limit reached: measure what arrived */ }
        catch (HttpRequestException) { return null; }
        var seconds = watch.Elapsed.TotalSeconds;
        return total > 0 && seconds > 0 ? total * 8 / seconds / 1_000_000 : null;
    }
}

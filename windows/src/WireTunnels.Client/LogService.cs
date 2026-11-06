using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

namespace WireTunnels.Client;

public enum LogLevel { Info, Warning, Error }

/// Port of LogService.swift: timestamped lines with keys redacted, kept in memory for the Log view
/// and appended to `logs\WireTunnels.log` (rotated to `.1` at 5 MB).
public sealed partial class LogService
{
    public const int MaxEntries = 1000;
    private const long MaxFileBytes = 5 * 1024 * 1024;

    private readonly string _file;
    private readonly object _lock = new();
    private readonly LinkedList<string> _entries = new();

    public LogService(string file)
    {
        _file = file;
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    }

    public string FilePath => _file;

    /// Raised on the thread that logged; subscribers marshal to their UI thread.
    public event Action<string>? EntryAdded;
    public event Action? Cleared;

    public IReadOnlyList<string> Entries
    {
        get { lock (_lock) return _entries.ToList(); }
    }

    public void Info(string message) => Log(message, LogLevel.Info);
    public void Warning(string message) => Log(message, LogLevel.Warning);
    public void Error(string message) => Log(message, LogLevel.Error);

    public async Task<T> TimedAsync<T>(string step, Func<Task<T>> action)
    {
        var watch = Stopwatch.StartNew();
        Info($"{step} started");
        try
        {
            var result = await action();
            Info($"{step} completed in {Seconds(watch)}s");
            return result;
        }
        catch (Exception e)
        {
            Error($"{step} failed after {Seconds(watch)}s: {e.Message}");
            throw;
        }
    }

    public Task TimedAsync(string step, Func<Task> action) =>
        TimedAsync<bool>(step, async () => { await action(); return true; });

    public void Log(string message, LogLevel level)
    {
        var tag = level switch { LogLevel.Warning => "WARN", LogLevel.Error => "ERROR", _ => "INFO" };
        var line = $"[{DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture)}] [{tag}] {Redacted(message)}";
        lock (_lock)
        {
            _entries.AddLast(line);
            if (_entries.Count > MaxEntries) _entries.RemoveFirst();
            Append(line);
        }
        Debug.WriteLine(line);
        EntryAdded?.Invoke(line);
    }

    public void Clear()
    {
        lock (_lock)
        {
            _entries.Clear();
            try { File.Delete(_file); File.Delete(_file + ".1"); }
            catch (IOException) { }
        }
        Cleared?.Invoke();
    }

    /// Never writes a private or preshared key, even when one ends up in an error message.
    internal static string Redacted(string message)
    {
        message = KeyAssignment().Replace(message, "$1 = (hidden)");
        message = KeyFormatError().Replace(message, "WireGuard key is not the correct length or format (value hidden)");
        return Base64Key().Replace(message, "(hidden)");
    }

    private void Append(string line)
    {
        try
        {
            var info = new FileInfo(_file);
            if (info.Exists && info.Length > MaxFileBytes) File.Move(_file, _file + ".1", overwrite: true);
            else if (!info.Exists) Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            File.AppendAllText(_file, line + Environment.NewLine);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Logging must never break a tunnel operation; the in-memory entry is still shown.
        }
    }

    private static string Seconds(Stopwatch watch) => watch.Elapsed.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture);

    [GeneratedRegex(@"(?im)(privatekey|presharedkey)\s*=\s*[^\s]+")]
    private static partial Regex KeyAssignment();

    [GeneratedRegex(@"(?im)^.*Key is not the correct length or format.*$")]
    private static partial Regex KeyFormatError();

    [GeneratedRegex(@"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])")]
    private static partial Regex Base64Key();
}

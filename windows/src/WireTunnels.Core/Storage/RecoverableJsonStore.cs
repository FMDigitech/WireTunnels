using System.Text.Json;

namespace WireTunnels.Core.Storage;

public sealed class MetadataStorageException(string message) : IOException(message)
{
    public static MetadataStorageException Unrecoverable() =>
        new("Metadata could not be read and no valid backup is available. Existing files were left unchanged.");

    public static MetadataStorageException UnsafeFile() =>
        new("Metadata must be stored in a regular file. Existing files were left unchanged.");
}

/// Port of RecoverableJSONStore.swift: keeps a validated previous snapshot in `<file>.backup`
/// and refuses to overwrite unreadable data (a corrupt primary is preserved, never lost).
public sealed class RecoverableJsonStore<T>(string file, Func<T> emptyValue) where T : class
{
    private string Backup => file + ".backup";

    public string? RecoveryWarning { get; private set; }

    public T Load()
    {
        RecoveryWarning = null;
        byte[]? primary;
        try
        {
            primary = Read(file);
            if (primary is not null && TryDecode(primary) is { } value) return value;
        }
        catch (IOException)
        {
            // A readable backup can still recover a primary with a read error.
            return RecoverBackup();
        }

        if (Read(Backup) is { } saved)
        {
            var value = TryDecode(saved) ?? throw MetadataStorageException.Unrecoverable();
            RecoveryWarning = RecoveredMessage;
            return value;
        }
        if (primary is not null) throw MetadataStorageException.Unrecoverable();
        return emptyValue();
    }

    public void Save(T value)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(value, CoreJson.Options);
        var primary = Read(file);
        byte[] previous;
        if (primary is not null)
        {
            if (TryDecode(primary) is not null) previous = primary;
            else
            {
                if (Read(Backup) is not { } saved || TryDecode(saved) is null) throw MetadataStorageException.Unrecoverable();
                previous = saved;
                Write(primary, $"{file}.corrupt-{Guid.NewGuid()}");
            }
        }
        else if (Read(Backup) is { } saved)
        {
            if (TryDecode(saved) is null) throw MetadataStorageException.Unrecoverable();
            previous = saved;
        }
        else previous = JsonSerializer.SerializeToUtf8Bytes(emptyValue(), CoreJson.Options);

        // If creating the backup fails, the primary must remain untouched.
        Write(previous, Backup);
        Write(data, file);
        RecoveryWarning = null;
        if (primary is null)
        {
            // A new store has no previous populated snapshot: make the first backup useful too.
            try { Write(data, Backup); }
            catch (IOException e) { RecoveryWarning = $"Metadata was saved, but its recovery backup could not be updated: {e.Message}"; }
        }
    }

    private string RecoveredMessage =>
        $"Recovered {Path.GetFileName(file)} from its backup. The original file will be preserved on the next save.";

    private T RecoverBackup()
    {
        try
        {
            if (Read(Backup) is { } saved && TryDecode(saved) is { } value)
            {
                RecoveryWarning = RecoveredMessage;
                return value;
            }
        }
        catch (IOException) { }
        throw MetadataStorageException.Unrecoverable();
    }

    private static T? TryDecode(byte[] data)
    {
        try { return JsonSerializer.Deserialize<T>(data, CoreJson.Options); }
        catch (JsonException) { return null; }
    }

    private static byte[]? Read(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            if (Directory.Exists(path) || info.LinkTarget is not null) throw MetadataStorageException.UnsafeFile();
            return null;
        }
        if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw MetadataStorageException.UnsafeFile();
        return File.ReadAllBytes(path);
    }

    private static void Write(byte[] data, string path)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        if (File.Exists(path)) _ = Read(path); // refuses links before replacing them
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid()}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }
            // Atomic commit; nothing may throw after a successful move.
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}

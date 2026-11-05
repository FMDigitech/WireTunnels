using System.Text.Json;
using System.Text.Json.Serialization;

namespace WireTunnels.Core.Storage;

/// One JSON shape for disk and IPC: camelCase keys and enum values, matching the macOS store.
public static class CoreJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };
}

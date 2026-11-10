using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace WireTunnels.App.Services;

/// The macOS colour scheme: the AppKit system colours (light and dark variants) that the SwiftUI views use for
/// status, sidebar icons and badges, and the app's own accent colour (AccentColor.colorset, #7C4DFF, in App.xaml).
/// The brushes live in App.xaml under fixed keys; their colours follow the Windows light/dark setting.
public static class MacPalette
{
    public readonly record struct Swatch(string Brush, Color Light, Color Dark);

    private static Color C(uint rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    public static readonly Swatch Green = new("ConnectedBrush", C(0x34C759), C(0x30D158));
    public static readonly Swatch Red = new("ErrorBrush", C(0xFF3B30), C(0xFF453A));
    public static readonly Swatch Orange = new("WarningBrush", C(0xFF9500), C(0xFF9F0A));
    public static readonly Swatch Yellow = new("YellowBrush", C(0xFFCC00), C(0xFFD60A));
    public static readonly Swatch Blue = new("TxBrush", C(0x007AFF), C(0x0A84FF));
    public static readonly Swatch Purple = new("PurpleBrush", C(0xAF52DE), C(0xBF5AF2));
    public static readonly Swatch Indigo = new("IndigoBrush", C(0x5856D6), C(0x5E5CE6));
    public static readonly Swatch Teal = new("TealBrush", C(0x30B0C7), C(0x40C8E0));
    public static readonly Swatch Gray = new("GrayBrush", C(0x8E8E93), C(0x98989D));

    private static readonly Swatch[] All = [Green, Red, Orange, Yellow, Blue, Purple, Indigo, Teal, Gray];

    public static Color Pick(Swatch swatch, bool dark) => dark ? swatch.Dark : swatch.Light;

    public static bool SystemIsDark(UISettings settings) => settings.GetColorValue(UIColorType.Background) == Colors.Black;

    /// Recolours the shared brushes (every view uses the same instances, so they all update). Call on the UI thread.
    public static void Apply(bool dark)
    {
        foreach (var swatch in All)
            if (Application.Current.Resources[swatch.Brush] is SolidColorBrush brush) brush.Color = Pick(swatch, dark);
        // RX is green and TX blue, as in the macOS charts.
        if (Application.Current.Resources["RxBrush"] is SolidColorBrush rx) rx.Color = Pick(Green, dark);
    }
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using WireTunnels.App.Services;
using WireTunnels.Client;
using WireTunnels.Core.Config;

namespace WireTunnels.App.Views;

/// Import WireGuard Config (macOS ImportConfigView): pick or drop a `.conf` or a QR code image, or paste
/// a QR code from the clipboard; it is validated, imported right away, and its warnings are shown.
public sealed class ImportDialog : ContentDialog
{
    private readonly App _app;
    private readonly Window _owner;
    private readonly TextBlock _file = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _result = new() { IsClosable = false, IsOpen = false };
    private readonly StackPanel _warnings = new() { Spacing = 4 };
    private Guid? _imported;

    public ImportDialog(App app, XamlRoot root, Window owner)
    {
        _app = app;
        _owner = owner;
        XamlRoot = root;
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        Title = "Import WireGuard Config";
        CloseButtonText = "Close";

        var drop = new Border
        {
            AllowDrop = true,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1.5),
            BorderBrush = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Padding = new Thickness(24),
        };
        var dropContent = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        dropContent.Children.Add(new FontIcon { Glyph = "", FontSize = 32, Foreground = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] });
        dropContent.Children.Add(new TextBlock { Text = "Drop a .conf file or a QR code image here", HorizontalAlignment = HorizontalAlignment.Center, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        var browse = new Button { Content = "Browse…", HorizontalAlignment = HorizontalAlignment.Center };
        browse.Click += async (_, _) => await BrowseAsync();
        dropContent.Children.Add(browse);
        drop.Child = dropContent;
        drop.DragOver += (_, e) =>
        {
            if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy;
        };
        drop.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            if ((await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>().FirstOrDefault() is { } file) await ImportAsync(file.Path);
        };
        var paste = new Button { Content = "Paste QR Code from Clipboard", HorizontalAlignment = HorizontalAlignment.Center };
        paste.Click += async (_, _) => await PasteAsync();

        var panel = new StackPanel { Spacing = 14, Width = 460 };
        panel.Children.Add(new TextBlock
        {
            Text = "Choose a WireGuard configuration file (.conf) or a QR code image to import. It is validated, encrypted for your Windows account and added to your tunnel list.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        panel.Children.Add(drop);
        panel.Children.Add(paste);
        panel.Children.Add(_file);
        panel.Children.Add(_result);
        panel.Children.Add(_warnings);
        Content = panel;
    }

    /// The imported tunnel, if any.
    public async Task<Guid?> ShowImportAsync()
    {
        await ShowAsync();
        return _imported;
    }

    private async Task BrowseAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add(".conf");
        foreach (var extension in ImageExtensions) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, _owner.Handle());
        if (await picker.PickSingleFileAsync() is { } file) await ImportAsync(file.Path);
    }

    private static readonly string[] ImageExtensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff"];

    private async Task ImportAsync(string path)
    {
        _file.Text = path;
        _warnings.Children.Clear();
        if (ImageExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var file = await StorageFile.GetFileFromPathAsync(path);
                using var stream = await file.OpenReadAsync();
                ImportQr(await DecodeQrAsync(stream), Path.GetFileNameWithoutExtension(path));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
            {
                Show(InfoBarSeverity.Error, "Import Failed", "Unable to read that image.");
            }
            return;
        }
        if (!path.EndsWith(".conf", StringComparison.OrdinalIgnoreCase))
        {
            Show(InfoBarSeverity.Error, "Import Failed", "Only .conf files and QR code images are supported.");
            return;
        }
        Report(() => (_app.Manager.Import(path), TunnelManager.Inspect(path)));
    }

    private async Task PasteAsync()
    {
        _warnings.Children.Clear();
        _file.Text = "";
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Bitmap))
        {
            Show(InfoBarSeverity.Error, "Import Failed", "No image found on the clipboard.");
            return;
        }
        try
        {
            using var stream = await (await content.GetBitmapAsync()).OpenReadAsync();
            ImportQr(await DecodeQrAsync(stream), "QR Import");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Show(InfoBarSeverity.Error, "Import Failed", "Unable to read the clipboard image.");
        }
    }

    private static async Task<string?> DecodeQrAsync(Windows.Storage.Streams.IRandomAccessStream stream)
    {
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
        var pixels = await decoder.GetPixelDataAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            new Windows.Graphics.Imaging.BitmapTransform(), Windows.Graphics.Imaging.ExifOrientationMode.RespectExifOrientation,
            Windows.Graphics.Imaging.ColorManagementMode.DoNotColorManage);
        return QrCode.Decode(pixels.DetachPixelData(), (int)decoder.OrientedPixelWidth, (int)decoder.OrientedPixelHeight);
    }

    /// The decoded text goes through the same validation as a file. The name comes from the image (or
    /// "QR Import"), with a number added when a tunnel already has it.
    private void ImportQr(string? text, string name)
    {
        if (text is null)
        {
            Show(InfoBarSeverity.Error, "Import Failed", "No QR code found in that image.");
            return;
        }
        var taken = _app.Manager.Tunnels.Select(t => t.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unique = Enumerable.Range(1, 99).Select(n => n == 1 ? name : $"{name} {n}").FirstOrDefault(n => !taken.Contains(n)) ?? name;
        Report(() => (_app.Manager.Create(unique, text), WireGuardConfig.Parse(text)));
    }

    private void Report(Func<(WireTunnels.Core.Models.Tunnel Tunnel, WireGuardConfig Parsed)> import)
    {
        try
        {
            var (tunnel, parsed) = import();
            _imported = tunnel.Id;
            Show(InfoBarSeverity.Success, "Import Successful", $"Tunnel \"{tunnel.Name}\" has been added.");
            foreach (var warning in parsed.Warnings)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = (Brush)Application.Current.Resources["WarningBrush"] });
                row.Children.Add(new TextBlock { Text = Describe(warning), TextWrapping = TextWrapping.Wrap, MaxWidth = 420, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
                _warnings.Children.Add(row);
            }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or ConfigValidationException or UnauthorizedAccessException)
        {
            Show(InfoBarSeverity.Error, "Import Failed", e.Message);
        }
    }

    private void Show(InfoBarSeverity severity, string title, string message)
    {
        _result.Severity = severity;
        _result.Title = title;
        _result.Message = message;
        _result.IsOpen = true;
    }

    /// The macOS ConfigWarning texts.
    internal static string Describe(ConfigWarning warning) => warning switch
    {
        ConfigWarning.MissingDns => "DNS not configured",
        ConfigWarning.MissingEndpoint => "Endpoint not specified",
        ConfigWarning.FullTunnel => "AllowedIPs includes 0.0.0.0/0 — full tunnel mode",
        ConfigWarning.Ipv4RoutedWithoutAddress => "AllowedIPs routes all IPv4 traffic but there is no IPv4 Address, so IPv4 will leak",
        _ => "AllowedIPs routes all IPv6 traffic but there is no IPv6 Address, so IPv6 will leak",
    };
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using WireTunnels.App.ViewModels;
using WireTunnels.Client;

namespace WireTunnels.App.Views;

/// The detail pane of the selected tunnel (macOS TunnelDetailView, phase 3 sections).
public sealed partial class TunnelDetailView : UserControl
{
    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(
        nameof(Item), typeof(TunnelItem), typeof(TunnelDetailView), new PropertyMetadata(null, (d, _) => ((TunnelDetailView)d).OnItemChanged()));

    private App _app = null!;
    private ShellViewModel _vm = null!;
    private Action<Guid> _select = _ => { };
    private CancellationTokenSource? _test;

    public TunnelDetailView() => InitializeComponent();

    public TunnelItem? Item
    {
        get => (TunnelItem?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    private TunnelManager Manager => _vm.Manager;

    public void Initialize(App app, ShellViewModel vm, Action<Guid> select)
    {
        _app = app;
        _vm = vm;
        _select = select;
        NetworkSettings.Initialize(vm.Manager);
    }

    private void OnItemChanged()
    {
        _test?.Cancel();
        TestResult.Text = "";
        TestBusy.IsActive = false;
        SpeedTestUrl.Text = Item?.SpeedTestUrl ?? "";
        NetworkSettings.Show(Item?.Id);
        Bindings.Update();
    }

    private async void OnToggled(object sender, RoutedEventArgs e)
    {
        if (Item is not { } item || Toggle.IsOn == item.IsActive) return;
        if (Toggle.IsOn) await Manager.ConnectAsync(item.Id);
        else await Manager.DisconnectAsync(item.Id);
        Toggle.IsOn = item.IsActive;
    }

    private async void OnTestConnection(object sender, RoutedEventArgs e)
    {
        if (Item is not { } item) return;
        _test?.Cancel();
        var cts = _test = new CancellationTokenSource();
        TestBusy.IsActive = true;
        TestButton.IsEnabled = false;
        TestResult.Text = "";
        try
        {
            var result = await Manager.TestConnectionAsync(item.Id, cts.Token);
            if (!cts.IsCancellationRequested) TestResult.Text = result.Describe();
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (_test == cts)
            {
                TestBusy.IsActive = false;
                TestButton.IsEnabled = Item?.IsActive == true;
            }
        }
    }

    private void OnSpeedTestUrlCommitted(object sender, RoutedEventArgs e) => SaveSpeedTestUrl();

    private void OnSpeedTestUrlKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) SaveSpeedTestUrl();
    }

    private void SaveSpeedTestUrl()
    {
        if (Item is { } item && (item.SpeedTestUrl ?? "") != SpeedTestUrl.Text.Trim()) Manager.UpdateSpeedTestUrl(item.Id, SpeedTestUrl.Text);
    }

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        if (Item is { } item) Manager.ToggleFavorite(item.Id);
    }

    private async void OnEdit(object sender, RoutedEventArgs e)
    {
        if (Item is { } item) await TunnelEditorDialog.EditAsync(_app, XamlRoot, item.Id);
    }

    private void OnDuplicate(object sender, RoutedEventArgs e)
    {
        if (Item is not { } item) return;
        try { _select(Manager.Duplicate(item.Id).Id); }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or InvalidDataException or ConfigValidationException)
        {
            Manager.ErrorMessage = ex.Message;
        }
    }

    private async void OnDelete(object sender, RoutedEventArgs e)
    {
        if (Item is not { } item) return;
        var dialog = new ContentDialog
        {
            Title = $"Delete \"{item.Name}\"?",
            Content = "This action cannot be undone. The tunnel configuration file will be removed.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) Manager.Delete(item.Id);
    }
}

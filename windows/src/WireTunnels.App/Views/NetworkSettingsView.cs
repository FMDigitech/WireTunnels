using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using WireTunnels.Client;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.App.Views;

/// The network sections of the detail pane (macOS TunnelDetailView): IPv4/IPv6 leaks, kill switch,
/// split tunnel exclusions and split DNS. Rebuilt only when what it shows changes, so typing in its
/// text boxes survives the status poll.
public sealed class NetworkSettingsView : UserControl
{
    private readonly StackPanel _root = new() { Spacing = 16 };
    private TunnelManager _manager = null!;
    private Guid? _id;
    private string? _shown;

    public NetworkSettingsView() => Content = _root;

    public void Initialize(TunnelManager manager)
    {
        _manager = manager;
        manager.StateChanged += () => DispatcherQueue.TryEnqueue(Render);
    }

    public void Show(Guid? id)
    {
        _id = id;
        _shown = null;
        Render();
    }

    private void Render()
    {
        var t = _id is { } id ? _manager.Find(id) : null;
        var signature = t is null ? "" : JsonSerializer.Serialize(new object[]
        {
            t.Id, t.IsActive, t.Scope, t.IsKillSwitchEnabled, t.IpFamilyLeakWarningAcknowledged, t.ExcludedRoutes, t.EffectiveSplitDNSDomains,
            t.Dns, _manager.IsBusy(t.Id), _manager.LeaksOf(t.Id).Select(l => $"{l.Family}{l.Reason}{_manager.FixUnavailableReason(t.Id, l)}"),
            t.InventoryCommand, t.InventoryAllowedIPs.Count, t.InventoryUpdatedAt, _manager.InventoryErrorOf(t.Id), _manager.IsRefreshingInventory(t.Id),
        });
        if (signature == _shown) return;
        _shown = signature;
        _root.Children.Clear();
        if (t is null) return;
        foreach (var leak in _manager.LeaksOf(t.Id)) _root.Children.Add(LeakCard(t, leak));
        _root.Children.Add(KillSwitchCard(t));
        if (t.Scope == TunnelScope.Personal) _root.Children.Add(ExclusionsCard(t));
        _root.Children.Add(SplitDnsCard(t));
        if (t.Scope == TunnelScope.Personal) _root.Children.Add(InventoryCard(t));
    }

    /// Port of InventorySettingsView.
    private Border InventoryCard(Tunnel t)
    {
        var editable = !t.IsActive && !_manager.IsBusy(t.Id);
        var command = t.InventoryCommand;
        var executable = new TextBox
        {
            Header = "Executable", PlaceholderText = @"C:\Path\To\python.exe", Text = command?.Executable ?? "", IsEnabled = editable,
            FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], IsSpellCheckEnabled = false,
        };
        var arguments = new TextBox
        {
            Header = "Arguments, one per line", Text = string.Join("\r", command?.Arguments ?? []), AcceptsReturn = true, MinHeight = 64,
            TextWrapping = TextWrapping.Wrap, IsEnabled = editable, FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], IsSpellCheckEnabled = false,
        };
        AutomationProperties.SetName(executable, "Inventory executable");
        AutomationProperties.SetName(arguments, "Inventory arguments");

        var items = new List<UIElement>
        {
            Caption("Runs a command as you after this tunnel connects and adds the IP addresses and CIDRs it prints to the tunnel's AllowedIPs. "
                + "Those destinations stay blocked outside this tunnel, also while it is disconnected, until you remove the command. "
                + "The command runs directly, without a shell, for at most 60 seconds."),
            executable,
            arguments,
        };
        if (command is not null)
            items.Add(Caption(t.InventoryUpdatedAt is { } updated
                ? $"{t.InventoryAllowedIPs.Count} discovered prefix(es), updated {updated.ToLocalTime():g}."
                : "No inventory fetched yet: only the config's AllowedIPs are protected."));
        if (_manager.InventoryErrorOf(t.Id) is { } error)
            items.Add(new TextBlock
            {
                Text = error, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["WarningBrush"],
            });
        if (t.IsActive) items.Add(Caption("Disconnect the tunnel to change its inventory command."));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var save = new Button { Content = "Save Command", IsEnabled = editable };
        save.Click += async (_, _) => await RunAsync(() => _manager.UpdateInventoryCommandAsync(t.Id, new Core.Models.InventoryCommand
        {
            Executable = executable.Text.Trim(),
            Arguments = [.. arguments.Text.Split((char[])['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)],
        }));
        buttons.Children.Add(save);
        if (command is not null)
        {
            var remove = new Button { Content = "Disable and Remove Protection", IsEnabled = editable };
            remove.Click += async (_, _) => await RunAsync(() => _manager.UpdateInventoryCommandAsync(t.Id, null));
            buttons.Children.Add(remove);
            var refresh = new Button { Content = "Refresh Now", IsEnabled = t.IsActive && !_manager.IsRefreshingInventory(t.Id) };
            refresh.Click += async (_, _) => await _manager.RefreshInventoryAsync(t.Id);
            buttons.Children.Add(refresh);
            if (_manager.IsRefreshingInventory(t.Id)) buttons.Children.Add(new ProgressRing { Width = 18, Height = 18, IsActive = true });
        }
        items.Add(buttons);
        return Card("Inventory AllowedIPs", "", [.. items]);
    }

    private async Task RunAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception e) when (e is InventoryException or ServiceException or IOException or InvalidDataException or System.Security.Cryptography.CryptographicException)
        {
            _manager.ErrorMessage = e.Message;
        }
    }

    private Border LeakCard(Tunnel t, IPFamilyLeak leak)
    {
        var fix = new Button { Content = $"Disable {leak.Family.DisplayName()} for This Tunnel" };
        fix.Click += async (_, _) => await _manager.FixIpFamilyLeakAsync(t.Id, leak);
        var reason = _manager.FixUnavailableReason(t.Id, leak);
        fix.IsEnabled = reason is null;
        var body = new List<UIElement> { Caption(leak.Problem) };
        if (leak.FixDescription is { } description)
        {
            body.Add(Caption(reason switch
            {
                IPFamilyLeakFix.UnavailableReason.DnsUsesFamily => IPFamilyLeakFix.DnsUnavailableMessage(leak.Family),
                IPFamilyLeakFix.UnavailableReason.Managed => "Ask your administrator to fix this shared tunnel.",
                IPFamilyLeakFix.UnavailableReason.Busy => "Wait for the current operation on this tunnel to finish.",
                _ => description + " The tunnel reconnects to apply it.",
            }));
            body.Add(fix);
        }
        var card = Card(leak.Title, "", [.. body]);
        card.BorderBrush = (Brush)Application.Current.Resources["WarningBrush"];
        return card;
    }

    private Border KillSwitchCard(Tunnel t)
    {
        var managed = t.Scope == TunnelScope.Managed;
        var items = new List<UIElement>();
        if (managed) items.Add(Caption("Set by your administrator and applied to all users. You can't change it here."));
        items.Add(Toggle("Block traffic if this tunnel drops", t.IsKillSwitchEnabled, !managed,
            on => _ = _manager.UpdateKillSwitchAsync(t.Id, on)));
        items.Add(Caption("Blocks all other network traffic until this tunnel reconnects. Disconnecting it yourself does not trigger a block."));
        if (!managed)
        {
            items.Add(Toggle("Don't warn about IPv4 / IPv6 leaks for this tunnel", t.IpFamilyLeakWarningAcknowledged, true,
                on => _manager.UpdateIpFamilyLeakAcknowledgement(t.Id, on)));
            items.Add(Caption("Use this if routing only one IP family is intentional."));
        }
        return Card("Kill Switch", "", [.. items]);
    }

    private Border ExclusionsCard(Tunnel t)
    {
        var items = new List<UIElement>
        {
            Caption("Traffic to these ranges bypasses this tunnel and goes out your regular connection instead, even while connected."),
        };
        foreach (var cidr in t.ExcludedRoutes)
            items.Add(Row(cidr, "", $"Remove {cidr}", async () => await _manager.UpdateExcludedRoutesAsync(t.Id, t.ExcludedRoutes.Where(r => r != cidr).ToList())));
        items.Add(AddBox("CIDR to exclude, e.g. 10.0.5.0/24", "Add excluded range", value =>
            value.Length > 0 && !t.ExcludedRoutes.Contains(value)
                ? _manager.UpdateExcludedRoutesAsync(t.Id, [.. t.ExcludedRoutes, value])
                : Task.CompletedTask));
        return Card("Split Tunnel Exclusions", "", [.. items]);
    }

    private Border SplitDnsCard(Tunnel t)
    {
        var editable = t.Scope == TunnelScope.Personal;
        var domains = t.EffectiveSplitDNSDomains;
        var items = new List<UIElement>
        {
            Caption("Use this tunnel's DNS servers only for these domains (e.g. lan, corp.example); every other name keeps using your normal DNS. Adding the first domain or removing the last one reconnects the tunnel."),
        };
        if (WireGuardDns.Servers(t.Dns).Count == 0)
            items.Add(new TextBlock
            {
                Text = "This tunnel has no DNS server configured, so there is nothing to route.",
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["WarningBrush"],
            });
        foreach (var domain in domains)
            items.Add(Row(domain, "", editable ? $"Remove {domain}" : null, () => SaveSplitDnsAsync(t, domains.Where(d => d != domain).ToList())));
        if (editable)
            items.Add(AddBox("Domain, e.g. lan or corp.example", "Add split DNS domain", value =>
            {
                if (WireGuardDns.NormalizedDomain(value) is not { } domain)
                {
                    if (value.Length > 0) _manager.ErrorMessage = $"\"{value}\" is not a valid domain name.";
                    return Task.CompletedTask;
                }
                return domains.Contains(domain) ? Task.CompletedTask : SaveSplitDnsAsync(t, [.. domains, domain]);
            }));
        return Card("Split DNS", "", [.. items]);
    }

    private async Task SaveSplitDnsAsync(Tunnel t, List<string> domains)
    {
        var reconnect = false;
        if (_manager.SplitDnsChangeNeedsReconnect(t.Id, domains))
        {
            var dialog = new ContentDialog
            {
                Title = $"Reconnect {t.Name} to apply this change?",
                Content = "This briefly interrupts the connection. Without a reconnect the tunnel's DNS stays as it was until the next connect.",
                PrimaryButtonText = "Reconnect Now",
                SecondaryButtonText = "Apply Later",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = XamlRoot,
            };
            var choice = await dialog.ShowAsync();
            if (choice == ContentDialogResult.None) return;
            reconnect = choice == ContentDialogResult.Primary;
        }
        await _manager.UpdateSplitDnsDomainsAsync(t.Id, domains, reconnect);
    }

    // MARK: building blocks

    private static Border Card(string title, string glyph, params UIElement[] content)
    {
        var stack = new StackPanel { Spacing = 8 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        head.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["SectionTitle"] });
        stack.Children.Add(head);
        foreach (var element in content) stack.Children.Add(element);
        return new Border { Style = (Style)Application.Current.Resources["Card"], Child = stack };
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private static ToggleSwitch Toggle(string header, bool value, bool enabled, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { Header = header, IsOn = value, IsEnabled = enabled };
        AutomationProperties.SetName(toggle, header);
        toggle.Toggled += (_, _) => { if (toggle.IsOn != value) changed(toggle.IsOn); };
        return toggle;
    }

    private static Grid Row(string text, string glyph, string? removeLabel, Func<Task> remove)
    {
        var row = new Grid { Padding = new Thickness(8, 4, 4, 4), CornerRadius = new CornerRadius(6), Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"] };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], Margin = new Thickness(0, 0, 8, 0) });
        var label = new TextBlock { Text = text, FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = true };
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        if (removeLabel is not null)
        {
            var button = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            AutomationProperties.SetName(button, removeLabel);
            ToolTipService.SetToolTip(button, removeLabel);
            button.Click += async (_, _) => await remove();
            Grid.SetColumn(button, 2);
            row.Children.Add(button);
        }
        return row;
    }

    private static Grid AddBox(string placeholder, string name, Func<string, Task> add)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var box = new TextBox { PlaceholderText = placeholder, FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], IsSpellCheckEnabled = false };
        AutomationProperties.SetName(box, name);
        var button = new Button { Content = "Add" };
        AutomationProperties.SetName(button, name);
        async Task Submit()
        {
            var value = box.Text.Trim();
            box.Text = "";
            await add(value);
        }
        button.Click += async (_, _) => await Submit();
        box.KeyDown += async (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            e.Handled = true;
            await Submit();
        };
        Grid.SetColumn(button, 1);
        grid.Children.Add(box);
        grid.Children.Add(button);
        return grid;
    }
}

using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WireTunnels.Client;
using WireTunnels.Core.Models;

namespace WireTunnels.App.Views;

/// Multi-Hop page (macOS HopChainView): the chains, connect / disconnect / remove, and a form for a new one.
public sealed class MultiHopView : UserControl
{
    private readonly StackPanel _chains = new() { Spacing = 10 };
    private readonly ComboBox _hop = new() { Header = "Hop", PlaceholderText = "Choose a tunnel", MinWidth = 220 };
    private readonly ComboBox _exit = new() { Header = "Exit", PlaceholderText = "Choose a tunnel", MinWidth = 220 };
    private TunnelManager _manager = null!;
    private string? _shown;

    private sealed record Choice(Guid Id, string Name)
    {
        public override string ToString() => Name; // what the ComboBox shows
    }

    public void Initialize(TunnelManager manager)
    {
        _manager = manager;
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(24, 16, 24, 24), MaxWidth = 820, HorizontalAlignment = HorizontalAlignment.Left };
        panel.Children.Add(new TextBlock { Text = "Multi-Hop", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        panel.Children.Add(Caption("Route a tunnel's traffic through another tunnel first, so the exit server sees the hop's IP instead of yours."));
        panel.Children.Add(_chains);

        var add = new Button { Content = "Add Chain", VerticalAlignment = VerticalAlignment.Bottom };
        add.Click += (_, _) =>
        {
            if (_hop.SelectedItem is not Choice hop || _exit.SelectedItem is not Choice exit) return;
            if (hop.Id == exit.Id)
            {
                _manager.ErrorMessage = "Choose two different tunnels.";
                return;
            }
            _manager.AddHopChain(hop.Id, exit.Id);
        };
        var pickers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        pickers.Children.Add(_hop);
        pickers.Children.Add(_exit);
        pickers.Children.Add(add);
        var form = new StackPanel { Spacing = 10 };
        form.Children.Add(new TextBlock { Text = "New Chain", Style = (Style)Application.Current.Resources["SectionTitle"] });
        form.Children.Add(pickers);
        form.Children.Add(Caption("Both tunnels must be disconnected and personal (not shared). Connecting the chain brings the hop up first, then routes the exit tunnel's own traffic through it."));
        panel.Children.Add(new Border { Style = (Style)Application.Current.Resources["Card"], Child = form });

        Content = new ScrollViewer { Content = panel };
        manager.StateChanged += () => DispatcherQueue.TryEnqueue(Render);
        manager.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    private void Render()
    {
        var m = _manager;
        var signature = JsonSerializer.Serialize(new object[]
        {
            m.HopChains.Select(c => new object?[] { c.Id, TunnelName(c.HopTunnelID), TunnelName(c.ExitTunnelID), m.IsChainActive(c), m.IsChainBusy(c.Id) }),
            m.Tunnels.Select(t => new object[] { t.Id, t.Name, t.Scope, m.ChainOf(t.Id) is null }),
            m.CanConnectTunnels,
        });
        if (signature == _shown) return;
        _shown = signature;

        _chains.Children.Clear();
        if (m.HopChains.Count == 0)
            _chains.Children.Add(Caption("No chains yet. Pick a hop and an exit tunnel below."));
        foreach (var chain in m.HopChains) _chains.Children.Add(ChainCard(chain));

        // Only personal tunnels that are not in a chain yet can be paired.
        var free = m.Tunnels.Where(t => t.Scope == TunnelScope.Personal && m.ChainOf(t.Id) is null).Select(t => new Choice(t.Id, t.Name)).ToList();
        Refill(_hop, free);
        Refill(_exit, free);
    }

    private static void Refill(ComboBox box, List<Choice> choices)
    {
        var selected = (box.SelectedItem as Choice)?.Id;
        box.ItemsSource = choices;
        box.SelectedItem = choices.FirstOrDefault(c => c.Id == selected);
    }

    private string? TunnelName(Guid id) => _manager.Find(id)?.Name;

    private Border ChainCard(HopChain chain)
    {
        var m = _manager;
        var active = m.IsChainActive(chain);
        var busy = m.IsChainBusy(chain.Id);

        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel { Spacing = 2 };
        var route = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        route.Children.Add(new TextBlock { Text = TunnelName(chain.HopTunnelID) ?? "Deleted tunnel", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        route.Children.Add(new FontIcon { Glyph = "", FontSize = 12 });
        route.Children.Add(new TextBlock { Text = TunnelName(chain.ExitTunnelID) ?? "Deleted tunnel", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        text.Children.Add(route);
        text.Children.Add(Caption(busy ? "Working…" : active ? "Connected: your traffic leaves through the exit server." : "Disconnected"));
        grid.Children.Add(text);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (busy) buttons.Children.Add(new ProgressRing { Width = 18, Height = 18, IsActive = true });
        var toggle = new Button { Content = active ? "Disconnect" : "Connect", IsEnabled = !busy && (active || m.CanConnectTunnels) };
        ToolTipService.SetToolTip(toggle, active ? "Disconnect this chain" : m.ConnectionUnavailableReason ?? "Connect this chain");
        toggle.Click += async (_, _) =>
        {
            if (active) await m.DisconnectHopChainAsync(chain.Id);
            else await m.ConnectHopChainAsync(chain.Id);
        };
        var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = !busy && !active };
        AutomationProperties.SetName(remove, "Remove chain");
        ToolTipService.SetToolTip(remove, active ? "Disconnect the chain before removing it" : "Remove chain");
        remove.Click += (_, _) => m.RemoveHopChain(chain.Id);
        buttons.Children.Add(toggle);
        buttons.Children.Add(remove);
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(buttons);
        return new Border { Style = (Style)Application.Current.Resources["Card"], Child = grid };
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
}

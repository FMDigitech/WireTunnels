using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using WireTunnels.Client;
using WireTunnels.Core.Models;

namespace WireTunnels.App.ViewModels;

/// Sidebar sections of the dashboard (macOS SidebarItem). Settings and Log are separate pages.
public enum TunnelSection { All, Active, Shared, Favorites }

/// Shared by the tray flyout and the dashboard: keeps their collections in step with the
/// TunnelManager, updating items in place instead of rebuilding the lists.
public sealed partial class ShellViewModel : ObservableObject
{
    private readonly Dictionary<Guid, TunnelItem> _items = [];
    private TunnelSection _section = TunnelSection.All;

    public ShellViewModel(TunnelManager manager)
    {
        Manager = manager;
        manager.StateChanged += Refresh;
        manager.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(TunnelManager.SetupState) or nameof(TunnelManager.IsShuttingDown)
                or nameof(TunnelManager.IsInitialized) or nameof(TunnelManager.Warnings)) Refresh();
        };
    }

    public TunnelManager Manager { get; }

    public ObservableCollection<TunnelItem> VisibleItems { get; } = [];
    public ObservableCollection<TunnelItem> ActiveItems { get; } = [];
    public ObservableCollection<TunnelItem> InactiveItems { get; } = [];
    public ObservableCollection<TunnelItem> FeedbackItems { get; } = [];
    public ObservableCollection<WarningItem> WarningItems { get; } = [];

    [ObservableProperty] private int _totalCount;
    [ObservableProperty] private int _activeCount;
    [ObservableProperty] private int _sharedCount;
    [ObservableProperty] private int _favoriteCount;
    [ObservableProperty] private int _warningCount;
    [ObservableProperty] private bool _hasInactiveFavorites;
    [ObservableProperty] private bool _hasActive;
    [ObservableProperty] private bool _hasInactive;
    [ObservableProperty] private bool _hasNoTunnels;
    [ObservableProperty] private bool _isSectionEmpty;
    [ObservableProperty] private string _sectionTitle = "All Tunnels";
    [ObservableProperty] private string _sectionSubtitle = "";
    [ObservableProperty] private string _emptyTitle = "";
    [ObservableProperty] private string _emptyMessage = "";
    [ObservableProperty] private string _emptyGlyph = "";
    [ObservableProperty] private bool _anyBusy;
    [ObservableProperty] private string? _setupNotice;
    [ObservableProperty] private ConnectionStatus _trayStatus;

    public bool HasWarnings => WarningCount > 0;
    public bool HasSetupNotice => SetupNotice is not null;
    partial void OnWarningCountChanged(int value) => OnPropertyChanged(nameof(HasWarnings));
    partial void OnSetupNoticeChanged(string? value) => OnPropertyChanged(nameof(HasSetupNotice));

    public TunnelItem? ItemFor(Guid id) => _items.GetValueOrDefault(id);

    public TunnelSection Section
    {
        get => _section;
        set
        {
            if (_section == value) return;
            _section = value;
            Refresh();
        }
    }

    public void Refresh()
    {
        var m = Manager;
        var warned = m.Warnings.SelectMany(w => w.TunnelNames).ToHashSet();
        var tunnels = m.Tunnels;
        foreach (var id in _items.Keys.Where(id => tunnels.All(t => t.Id != id)).ToList()) _items.Remove(id);
        var items = tunnels.Select(t =>
        {
            if (!_items.TryGetValue(t.Id, out var item)) _items[t.Id] = item = new TunnelItem(t.Id);
            item.Update(t, m, warned);
            return (Tunnel: t, Item: item);
        }).ToList();

        var visible = _section switch
        {
            TunnelSection.Active => items.Where(p => p.Tunnel.IsActive),
            TunnelSection.Shared => items.Where(p => p.Tunnel.Scope == TunnelScope.Managed),
            TunnelSection.Favorites => items.Where(p => p.Tunnel.IsFavorite && p.Tunnel.Scope == TunnelScope.Personal),
            _ => items,
        };
        Sync(VisibleItems, visible.Select(p => p.Item).ToList());
        Sync(ActiveItems, items.Where(p => p.Tunnel.IsActive).Select(p => p.Item).ToList());
        Sync(InactiveItems, items.Where(p => !p.Tunnel.IsActive).Select(p => p.Item).ToList());
        Sync(FeedbackItems, items.Where(p => p.Item.HasFeedback).Select(p => p.Item).ToList());

        var warnings = m.Warnings.Select(w => new WarningItem(w.Title, w.Message)).ToList();
        if (!warnings.SequenceEqual(WarningItems))
        {
            WarningItems.Clear();
            foreach (var w in warnings) WarningItems.Add(w);
        }

        TotalCount = items.Count;
        ActiveCount = m.ActiveTunnelCount;
        SharedCount = m.SharedTunnels.Count();
        FavoriteCount = m.FavoriteTunnels.Count();
        WarningCount = warnings.Count;
        HasInactiveFavorites = m.FavoriteTunnels.Any(t => !t.IsActive);
        HasActive = m.HasActiveTunnels;
        HasInactive = InactiveItems.Count > 0;
        HasNoTunnels = items.Count == 0;
        AnyBusy = items.Any(p => p.Item.IsBusy);
        TrayStatus = m.TrayStatus;
        SetupNotice = m.IsInitialized && m.NeedsSetup ? m.ConnectionUnavailableReason : null;
        UpdateSectionText();
    }

    private void UpdateSectionText()
    {
        var count = VisibleItems.Count;
        string Plural(string word) => $"{count} {word}{(count == 1 ? "" : "s")}";
        (SectionTitle, SectionSubtitle, EmptyTitle, EmptyMessage, EmptyGlyph) = _section switch
        {
            TunnelSection.Active => ("Active", $"{count} connected", "No Active Tunnels", "Connect a tunnel to see it here.", ""),
            TunnelSection.Shared => ("Shared", $"{count} shared", "No Shared Tunnels",
                "Tunnels shared with every user of this PC arrive with a later WireTunnels version.", ""),
            TunnelSection.Favorites => ("Favorites", Plural("favorite"), "No Favorites", "Star a tunnel to mark it as a favorite.", ""),
            _ => ("All Tunnels", $"{Plural("tunnel")}, {ActiveCount} active", "No Tunnels",
                "Import a .conf file or create a new tunnel to get started.", ""),
        };
        IsSectionEmpty = count == 0;
    }

    /// Makes `target` equal `desired` (same items, same order) with the fewest collection changes.
    private static void Sync(ObservableCollection<TunnelItem> target, IReadOnlyList<TunnelItem> desired)
    {
        var keep = desired.ToHashSet();
        for (var i = target.Count - 1; i >= 0; i--)
            if (!keep.Contains(target[i])) target.RemoveAt(i);
        for (var i = 0; i < desired.Count; i++)
        {
            var current = target.IndexOf(desired[i]);
            if (current == i) continue;
            if (current < 0) target.Insert(i, desired[i]);
            else target.Move(current, i);
        }
    }
}

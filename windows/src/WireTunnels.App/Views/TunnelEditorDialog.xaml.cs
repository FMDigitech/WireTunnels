using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using WireTunnels.Client;
using WireTunnels.Core.Config;

namespace WireTunnels.App.Views;

/// New Tunnel and Edit Config (macOS NewTunnelView / ConfigEditorSheetView): a basic form or
/// the advanced editor with templates. Errors stay inside the dialog instead of closing it.
public sealed partial class TunnelEditorDialog : ContentDialog
{
    private readonly App _app;
    private readonly Guid? _editing;
    private bool _loading;
    private string _generatedPrivateKey = "";

    private TunnelEditorDialog(App app, XamlRoot root, Guid? editing)
    {
        _app = app;
        _editing = editing;
        XamlRoot = root;
        InitializeComponent();
        foreach (var template in ConfigTemplate.All)
        {
            var item = new MenuFlyoutItem { Text = template.Name, Icon = new FontIcon { Glyph = template.Glyph } };
            ToolTipService.SetToolTip(item, template.Description);
            item.Click += (_, _) => _ = InsertTemplateAsync(template);
            TemplateMenu.Items.Add(item);
        }
        Editor.TextChanged += Validate;
        Error.Closed += (_, _) => Error.Message = "";
    }

    private TunnelManager Manager => _app.Manager;
    private bool IsAdvanced => Tabs.SelectedItem == AdvancedTab;

    /// The id of the created tunnel, or null when cancelled.
    public static async Task<Guid?> CreateAsync(App app, XamlRoot root)
    {
        var dialog = new TunnelEditorDialog(app, root, null)
        {
            Title = "New Tunnel",
            PrimaryButtonText = "Save & Connect",
            SecondaryButtonText = "Save",
        };
        dialog.Validate();
        await dialog.ShowAsync();
        return dialog.CreatedId;
    }

    public static async Task EditAsync(App app, XamlRoot root, Guid id)
    {
        string contents;
        try { contents = app.Manager.ReadConfig(id); }
        catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException or UnauthorizedAccessException)
        {
            app.Manager.ErrorMessage = $"Unable to load configuration: {e.Message}";
            return;
        }
        var tunnel = app.Manager.Find(id);
        var dialog = new TunnelEditorDialog(app, root, id)
        {
            Title = $"Edit Config — {tunnel?.Name}",
            PrimaryButtonText = "Save",
        };
        dialog.Load(tunnel?.Name ?? "", contents);
        dialog.Tabs.SelectedItem = dialog.AdvancedTab; // macOS opens the editor on the Advanced tab
        await dialog.ShowAsync();
    }

    public Guid? CreatedId { get; private set; }

    private void Load(string name, string contents)
    {
        _loading = true;
        NameBox.Text = name;
        Editor.Text = contents;
        Fill(BasicConfigForm.From(contents));
        _loading = false;
        Validate();
    }

    private void Fill(BasicConfigForm form)
    {
        PrivateKeyBox.Password = form.PrivateKey;
        AddressBox.Text = form.Address;
        DnsBox.Text = form.Dns;
        SearchBox.Text = form.SearchDomains;
        PeerKeyBox.Text = form.PeerPublicKey;
        PskBox.Text = form.PresharedKey;
        EndpointBox.Text = form.Endpoint;
        AllowedBox.Text = form.AllowedIPs;
        KeepaliveBox.Text = form.PersistentKeepalive;
    }

    private BasicConfigForm Form() => new()
    {
        PrivateKey = PrivateKeyBox.Password,
        Address = AddressBox.Text,
        Dns = DnsBox.Text,
        SearchDomains = SearchBox.Text,
        PeerPublicKey = PeerKeyBox.Text,
        PresharedKey = PskBox.Text,
        Endpoint = EndpointBox.Text,
        AllowedIPs = AllowedBox.Text,
        PersistentKeepalive = KeepaliveBox.Text,
    };

    private string EffectiveConfig => IsAdvanced ? Editor.Text : Form().ToConfig();

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        BasicPanel.Visibility = IsAdvanced ? Visibility.Collapsed : Visibility.Visible;
        AdvancedPanel.Visibility = IsAdvanced ? Visibility.Visible : Visibility.Collapsed;
        // As on macOS the two tabs keep their own content; an empty editor starts from the form.
        // (Regenerating the text from the form would drop comments and extra peers.)
        if (IsAdvanced && Editor.Text.Trim().Length == 0)
        {
            _loading = true;
            Editor.Text = Form().ToConfig();
            _loading = false;
        }
        Validate();
    }

    private void OnChanged(object sender, TextChangedEventArgs e) => Validate();

    private void OnPrivateKeyChanged(object sender, RoutedEventArgs e)
    {
        if (_generatedPrivateKey.Length > 0 && PrivateKeyBox.Password != _generatedPrivateKey)
        {
            _generatedPrivateKey = "";
            PublicKeyRow.Visibility = Visibility.Collapsed;
        }
        Validate();
    }

    private void Validate()
    {
        if (_loading) return;
        var name = NameBox.Text.Trim();
        bool canSave;
        if (IsAdvanced) canSave = name.Length > 0 && Editor.Text.Trim().Length > 0;
        else
        {
            var form = Form();
            var invalid = form.InvalidSearchDomains;
            SearchError.Text = invalid.Count > 0 ? $"Not a valid domain: {string.Join(", ", invalid)}" : "";
            SearchError.Visibility = invalid.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            canSave = name.Length > 0 && form.CanSave;
        }
        IsSecondaryButtonEnabled = canSave;
        IsPrimaryButtonEnabled = canSave && (_editing is not null || Manager.CanConnectTunnels);
    }

    private void OnGenerateKey(object sender, RoutedEventArgs e)
    {
        var (priv, pub) = WireGuardKey.Generate();
        _generatedPrivateKey = priv;
        PrivateKeyBox.Password = priv;
        PublicKeyText.Text = pub;
        PublicKeyRow.Visibility = Visibility.Visible;
    }

    private void OnCopyPublicKey(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(PublicKeyText.Text);
        Clipboard.SetContent(package);
    }

    private async Task InsertTemplateAsync(ConfigTemplate template)
    {
        if (Editor.Text.Trim().Length > 0)
        {
            // A ContentDialog cannot open a second dialog: confirm inline with a flyout instead.
            var confirm = new Flyout();
            var panel = new StackPanel { Spacing = 10, MaxWidth = 280 };
            panel.Children.Add(new TextBlock { Text = "Replace Current Content?", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            panel.Children.Add(new TextBlock { Text = $"This will replace your current config with the \"{template.Name}\" template.", TextWrapping = TextWrapping.Wrap });
            var replace = new Button { Content = "Replace", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            var tcs = new TaskCompletionSource<bool>();
            replace.Click += (_, _) => { tcs.TrySetResult(true); confirm.Hide(); };
            confirm.Closed += (_, _) => tcs.TrySetResult(false);
            panel.Children.Add(replace);
            confirm.Content = panel;
            confirm.ShowAt(TemplateButton);
            if (!await tcs.Task) return;
        }
        Editor.Text = template.Content;
    }

    private void ShowError(string message)
    {
        Error.Title = "Unable to Save";
        Error.Message = message;
        Error.IsOpen = true;
    }

    /// New: "Save & Connect". Edit: "Save".
    private async void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (_editing is { } id)
        {
            if (!Save(() => Manager.Update(id, NameBox.Text, EffectiveConfig))) args.Cancel = true;
            return;
        }
        var deferral = args.GetDeferral();
        try
        {
            if (!Save(() => CreatedId = Manager.Create(NameBox.Text, EffectiveConfig).Id)) { args.Cancel = true; return; }
            if (CreatedId is { } created && Manager.CanConnectTunnels) await Manager.ConnectAsync(created);
        }
        finally { deferral.Complete(); }
    }

    private void OnSecondary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!Save(() => CreatedId = Manager.Create(NameBox.Text, EffectiveConfig).Id)) args.Cancel = true;
    }

    private bool Save(Action save)
    {
        try
        {
            save();
            return true;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException or ConfigValidationException or UnauthorizedAccessException)
        {
            ShowError(e.Message);
            return false;
        }
    }
}

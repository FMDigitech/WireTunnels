using Microsoft.UI;
using WireTunnels.App.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.UI;

namespace WireTunnels.App.Views;

/// Area + line sparkline of recent rates (the macOS Swift Charts sparkline), no axes.
public sealed class Sparkline : Grid
{
    public static readonly DependencyProperty ValuesProperty = DependencyProperty.Register(
        nameof(Values), typeof(IReadOnlyList<double>), typeof(Sparkline), new PropertyMetadata(null, (d, _) => ((Sparkline)d).Redraw()));

    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(
        nameof(Stroke), typeof(Brush), typeof(Sparkline), new PropertyMetadata(null, (d, _) => ((Sparkline)d).ApplyBrush()));

    private readonly Polyline _line = new() { StrokeThickness = 1.5, StrokeLineJoin = PenLineJoin.Round };
    private readonly Polygon _area = new() { Opacity = 0.18 };

    public Sparkline()
    {
        Children.Add(_area);
        Children.Add(_line);
        SizeChanged += (_, _) => Redraw();
        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    }

    public IReadOnlyList<double>? Values
    {
        get => (IReadOnlyList<double>?)GetValue(ValuesProperty);
        set => SetValue(ValuesProperty, value);
    }

    public Brush? Stroke
    {
        get => (Brush?)GetValue(StrokeProperty);
        set => SetValue(StrokeProperty, value);
    }

    private void ApplyBrush()
    {
        _line.Stroke = Stroke;
        _area.Fill = Stroke;
    }

    private void Redraw()
    {
        var values = Values ?? [];
        double w = ActualWidth, h = ActualHeight;
        var line = new PointCollection();
        var area = new PointCollection();
        if (values.Count > 0 && w > 0 && h > 0)
        {
            var max = Math.Max(values.Max(), 1);
            var step = values.Count > 1 ? w / (values.Count - 1) : 0;
            area.Add(new Point(0, h));
            for (var i = 0; i < values.Count; i++)
            {
                var p = new Point(values.Count > 1 ? i * step : w, h - 1 - values[i] / max * (h - 2));
                line.Add(p);
                area.Add(p);
            }
            area.Add(new Point(w, h));
        }
        _line.Points = line;
        _area.Points = area;
    }
}

/// "Label    value" row of the detail pane (macOS DetailRow): fixed label column, wrapping value.
public sealed class FieldRow : UserControl
{
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(FieldRow), new PropertyMetadata("", (d, e) => ((FieldRow)d)._label.Text = (string)e.NewValue));

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(string), typeof(FieldRow), new PropertyMetadata("", (d, e) => ((FieldRow)d)._value.Text = (string?)e.NewValue ?? ""));

    public static readonly DependencyProperty MonoProperty = DependencyProperty.Register(
        nameof(Mono), typeof(bool), typeof(FieldRow), new PropertyMetadata(false, (d, e) => ((FieldRow)d).ApplyFont((bool)e.NewValue)));

    private readonly TextBlock _label = new() { Width = 140, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _value = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    public FieldRow()
    {
        _label.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(_value, 1);
        grid.Children.Add(_label);
        grid.Children.Add(_value);
        Content = grid;
    }

    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public string Value { get => (string)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public bool Mono { get => (bool)GetValue(MonoProperty); set => SetValue(MonoProperty, value); }

    private void ApplyFont(bool mono)
    {
        if (mono) _value.FontFamily = (FontFamily)Application.Current.Resources["MonoFont"];
        else _value.ClearValue(TextBlock.FontFamilyProperty);
    }
}

/// The advanced editor: plain-text editing of a `.conf` with the macOS syntax colours
/// (sections, keys, comments). Pastes are always plain text.
public sealed class ConfigTextEditor : UserControl
{
    // ConfigEditorView.swift: comments green, [Interface] orange, [Peer] teal, keys blue, "=" secondary.
    private bool Dark => ActualTheme == ElementTheme.Dark;
    private Color InterfaceColor => MacPalette.Pick(MacPalette.Orange, Dark);
    private Color PeerColor => MacPalette.Pick(MacPalette.Teal, Dark);
    private Color KeyColor => MacPalette.Pick(MacPalette.Blue, Dark);
    private Color CommentColor => MacPalette.Pick(MacPalette.Green, Dark);
    private Color EqualsColor => MacPalette.Pick(MacPalette.Gray, Dark);

    private readonly RichEditBox _box = new()
    {
        AcceptsReturn = true,
        IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false,
        TextWrapping = TextWrapping.NoWrap,
        ClipboardCopyFormat = RichEditClipboardFormat.PlainText,
        DisabledFormattingAccelerators = DisabledFormattingAccelerators.All,
    };
    private bool _highlighting;
    private string _lastText = "";

    public ConfigTextEditor()
    {
        _box.FontFamily = (FontFamily)Application.Current.Resources["MonoFont"];
        Content = _box;
        _box.TextChanged += (_, _) => Highlight();
        _box.Paste += OnPaste;
        ActualThemeChanged += (_, _) => { _lastText = ""; Highlight(); };
        AutomationProperties.SetName(_box, "Configuration");
    }

    public event Action? TextChanged;

    public string Text
    {
        get
        {
            _box.Document.GetText(TextGetOptions.None, out var text);
            // RichEditBox uses \r line breaks and always ends with one.
            return text.TrimEnd('\r').Replace("\r", "\n");
        }
        set
        {
            _box.Document.SetText(TextSetOptions.None, value.Replace("\r\n", "\n").Replace('\n', '\r'));
            Highlight();
        }
    }

    private async void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) return;
        var text = (await content.GetTextAsync()).Replace("\r\n", "\n").Replace('\n', '\r');
        _box.Document.Selection.SetText(TextSetOptions.None, text);
        _box.Document.Selection.Collapse(false);
    }

    private void Highlight()
    {
        if (_highlighting) return;
        var doc = _box.Document;
        doc.GetText(TextGetOptions.None, out var text);
        if (text == _lastText) return; // a formatting pass also raises TextChanged
        _highlighting = true;
        try
        {
            doc.BatchDisplayUpdates();
            var normal = ActualTheme == ElementTheme.Dark ? Colors.White : Colors.Black;
            var start = 0;
            foreach (var line in text.Split('\r'))
            {
                ColorLine(doc, start, line, normal);
                start += line.Length + 1;
            }
            doc.ApplyDisplayUpdates();
            _lastText = text;
        }
        finally { _highlighting = false; }
        TextChanged?.Invoke();
    }

    private void ColorLine(RichEditTextDocument doc, int start, string line, Color normal)
    {
        var trimmed = line.Trim();
        void Paint(int from, int length, Color color, bool bold = false)
        {
            if (length <= 0) return;
            var range = doc.GetRange(start + from, start + from + length);
            range.CharacterFormat.ForegroundColor = color;
            range.CharacterFormat.Bold = bold ? FormatEffect.On : FormatEffect.Off;
        }
        Paint(0, line.Length, normal);
        if (trimmed.StartsWith('#')) Paint(0, line.Length, CommentColor);
        else if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            Paint(0, line.Length, trimmed.Contains("interface", StringComparison.OrdinalIgnoreCase) ? InterfaceColor : PeerColor, bold: true);
        else if (line.IndexOf('=') is var eq and >= 0)
        {
            Paint(0, eq, KeyColor);
            Paint(eq, 1, EqualsColor);
        }
    }
}

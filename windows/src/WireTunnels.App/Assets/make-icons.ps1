# Regenerates the app and tray icons (multi-size .ico with PNG frames). Run with Windows PowerShell:
#   powershell -NoProfile -File make-icons.ps1
# A tunnel portal (white arch) on a rounded square whose colour is the connection state.
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$states = [ordered]@{
    'app'        = '#2563EB'
    'idle'       = '#6B7280'
    'connected'  = '#16A34A'
    'connecting' = '#D97706'
    'warning'    = '#D97706'
    'error'      = '#DC2626'
}
$sizes = 16, 20, 24, 32, 40, 48, 64, 256

function New-Frame([int]$size, [string]$hex, [string]$state) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $white = [System.Drawing.Color]::White

    # Rounded square in the state colour.
    $pad = [Math]::Max(1, $size * 0.04)
    $box = $size - 2 * $pad
    $r = $box * 0.24
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($pad, $pad, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($pad + $box - 2 * $r, $pad, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($pad + $box - 2 * $r, $pad + $box - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($pad, $pad + $box - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush $color), $path)

    # Portal: a thick arch standing on the bottom, with a fainter inner arch for the tunnel depth.
    $stroke = [Math]::Max(1.6, $size * 0.13)
    $cx = $size / 2; $base = $size * 0.80; $outer = $size * 0.30
    $g.DrawArc((New-Object System.Drawing.Pen $white, $stroke), $cx - $outer, $base - $outer, 2 * $outer, 2 * $outer, 180, 180)
    if ($size -ge 20) {
        $thin = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(170, 255, 255, 255)), ([Math]::Max(1, $size * 0.06))
        $inner = $outer * 0.45
        $g.DrawArc($thin, $cx - $inner, $base - $inner, 2 * $inner, 2 * $inner, 180, 180)
    }

    # Badge: "!" in a white disc for warning/error, a plain white dot while connecting.
    if ($state -in 'warning', 'error') {
        $b = $size * 0.34; $bx = $size - $b; $by = 0
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $white), $bx, $by, $b, $b)
        $mark = New-Object System.Drawing.Pen $color, ([Math]::Max(1.2, $b * 0.2))
        $g.DrawLine($mark, $bx + $b / 2, $by + $b * 0.20, $bx + $b / 2, $by + $b * 0.56)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), $bx + $b * 0.39, $by + $b * 0.66, $b * 0.22, $b * 0.22)
    }
    elseif ($state -eq 'connecting') {
        $b = $size * 0.28
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $white), $size - $b, 0, $b, $b)
    }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    if ($size -ge 256) {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    else {
        # Classic 32-bit DIB frame (BITMAPINFOHEADER, bottom-up BGRA, AND mask): every icon reader
        # accepts it, while PNG frames below 256 px are not read by GDI+ (System.Drawing.Icon).
        $bw = New-Object System.IO.BinaryWriter $ms
        $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
        $bw.Write([UInt32]40); $bw.Write([Int32]$size); $bw.Write([Int32]($size * 2))
        $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
        $bw.Write([UInt32]($size * $size * 4 + $maskStride * $size))
        $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([UInt32]0); $bw.Write([UInt32]0)
        for ($y = $size - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $size; $x++) {
                $p = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$p.B); $bw.Write([byte]$p.G); $bw.Write([byte]$p.R); $bw.Write([byte]$p.A)
            }
        }
        $bw.Write((New-Object byte[] ($maskStride * $size))) # alpha decides; mask all-opaque
        $bw.Flush()
    }
    $bmp.Dispose()
    return , $ms.ToArray()
}

foreach ($state in $states.Keys) {
    $frames = foreach ($s in $sizes) { , (New-Frame $s $states[$state] $state) }
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $len = $frames[$i].Length
        $dim = if ($s -ge 256) { 0 } else { $s }
        $w.Write([byte]$dim); $w.Write([byte]$dim)
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([UInt16]1); $w.Write([UInt16]32)
        $w.Write([UInt32]$len); $w.Write([UInt32]$offset)
        $offset += $len
    }
    foreach ($f in $frames) { $w.Write($f) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot "$state.ico"), $out.ToArray())
    if ($state -eq 'app') { [System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'app-256.png'), $frames[-1]) }
}
"Icons written to $PSScriptRoot"

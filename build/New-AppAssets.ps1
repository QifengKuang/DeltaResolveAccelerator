$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $root 'src/app.ico'
$images = [Collections.Generic.List[byte[]]]::new()
$sizes = @(16, 24, 32, 48, 64, 128, 256)
foreach ($size in $sizes) {
    $bitmap = [Drawing.Bitmap]::new($size,$size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $stream = [IO.MemoryStream]::new()
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::Transparent)
        $background = [Drawing.Drawing2D.GraphicsPath]::new()
        $backgroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(229,241,224))
        try {
            $diameter = [single](($size-1)*.42)
            $edge = [single]($size-1-$diameter)
            $background.AddArc([single]0,[single]0,$diameter,$diameter,[single]180,[single]90)
            $background.AddArc($edge,[single]0,$diameter,$diameter,[single]270,[single]90)
            $background.AddArc($edge,$edge,$diameter,$diameter,[single]0,[single]90)
            $background.AddArc([single]0,$edge,$diameter,$diameter,[single]90,[single]90)
            $background.CloseFigure()
            $graphics.FillPath($backgroundBrush,$background)
        } finally { $backgroundBrush.Dispose(); $background.Dispose() }
        $points = [Drawing.PointF[]]@(
            [Drawing.PointF]::new($size*.50,$size*.16),
            [Drawing.PointF]::new($size*.85,$size*.79),
            [Drawing.PointF]::new($size*.15,$size*.79))
        $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(46,105,76),[single]($size*.075))
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $graphics.DrawPolygon($pen,$points)
        $pen.Dispose()
        $brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(46,105,76))
        $graphics.FillEllipse($brush,[single]($size*.445),[single]($size*.535),[single]($size*.11),[single]($size*.11))
        $brush.Dispose()
        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
        $images.Add($stream.ToArray())
    } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}
$file = [IO.File]::Create($destination)
$writer = [IO.BinaryWriter]::new($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16*$sizes.Count
    for ($index=0;$index -lt $sizes.Count;$index++) {
        $byteSize = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$byteSize); $writer.Write([byte]$byteSize)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$index].Length); $writer.Write([uint32]$offset)
        $offset += $images[$index].Length
    }
    foreach ($bytes in $images) { $writer.Write($bytes) }
} finally { $writer.Dispose(); $file.Dispose() }
Write-Output $destination

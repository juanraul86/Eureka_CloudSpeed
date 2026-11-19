<#
.SYNOPSIS
    Genera los ejecutables de Eureka_CloudSpeed con el compilador de C# que incluye Windows
    (.NET Framework 4.x), sin descargar nada:
      ..\Eureka_CloudSpeed.exe                 lanzador que se coloca junto a la carpeta
      ..\Dist\Eureka_CloudSpeed_Portable.exe   un único archivo con todo dentro
      ..\Dist\Eureka_CloudSpeed.zip            la carpeta completa comprimida
.NOTES
    Vuelve a ejecutarlo cada vez que cambies el catálogo, el motor, los módulos o la interfaz.
    Sin firma, Smart App Control puede bloquear los .exe: usa -CertificateThumbprint o Eureka_CloudSpeed.cmd.
#>
[CmdletBinding()]
param(
    [string]$CertificateThumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$build = $PSScriptRoot
$root  = Split-Path $build -Parent
$dist  = Join-Path $root 'Dist'
$obj   = Join-Path $build 'obj'
foreach ($d in $dist, $obj) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'No se encuentra csc.exe de .NET Framework 4.x.' }
$fx = Split-Path $csc

# ---------------------------------------------------------------- icono (velocímetro sobre fondo azul)
Add-Type -AssemblyName System.Drawing
$ico = Join-Path $obj 'cloudspeed.ico'
function New-IconPng([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [math]::Max(2, [int]($s * 0.18)); $w = $s - 1
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($w - $r * 2, $w - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, $w - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(15, 108, 189))), $path)
    $th = [float][math]::Max(1.5, $s * 0.09)
    $cx = $s * 0.5; $cy = $s * 0.62; $rad = $s * 0.32
    $rect = New-Object System.Drawing.RectangleF ([float]($cx - $rad)), ([float]($cy - $rad)), ([float]($rad * 2)), ([float]($rad * 2))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(140, 255, 255, 255)), $th
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, $rect, 180, 180)
    $green = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(34, 197, 94)), $th
    $green.StartCap = 'Round'; $green.EndCap = 'Round'
    $g.DrawArc($green, $rect, 180, 70)
    $needle = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([float][math]::Max(1.2, $s * 0.07))
    $needle.EndCap = 'Round'
    $a = 215 * [math]::PI / 180
    $g.DrawLine($needle, [float]$cx, [float]$cy, [float]($cx + [math]::Cos($a) * $rad * 0.85), [float]($cy + [math]::Sin($a) * $rad * 0.85))
    $d = [float]([math]::Max(2, $s * 0.12))
    $g.FillEllipse([System.Drawing.Brushes]::White, [float]($cx - $d / 2), [float]($cy - $d / 2), $d, $d)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return , $ms.ToArray()
}
$sizes = 16, 24, 32, 48, 64, 256
$pngs = @($sizes | ForEach-Object { , (New-IconPng $_) })
$fs = [IO.File]::Create($ico); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $b = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
$uiIco = Join-Path $root 'UI\cloudspeed.ico'
if (-not (Test-Path $uiIco) -or (Get-FileHash $ico).Hash -ne (Get-FileHash $uiIco).Hash) {
    try { Copy-Item $ico $uiIco -Force -ErrorAction Stop }
    catch { Write-Warning "No se pudo actualizar UI\cloudspeed.ico (¿la app está abierta?). Se mantiene el actual." }
}

# ---------------------------------------------------------------- payload
$skip = '^(\.git|\.github|\.signpath|Tests|Build|Dist|Datos|Exportaciones|Config|Docs\\capturas-temp|Eureka_CloudSpeed_Datos)(\\|$)|\.exe$|\.log$|\.(bak|tmp)$|^\.gitignore$'
$files = Get-ChildItem $root -Recurse -File -Force | Where-Object { $_.FullName.Substring($root.Length + 1) -notmatch $skip }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-CsZip([string]$Path, $Items, [string]$Prefix) {
    if (Test-Path $Path) { Remove-Item $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($f in $Items) {
            $rel = $Prefix + $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, 'Optimal')
        }
    }
    finally { $zip.Dispose() }
}
$payload = Join-Path $obj 'payload.zip'
New-CsZip $payload $files ''
Write-Host ("Payload: {0} archivos, {1:N2} MB" -f @($files).Count, ((Get-Item $payload).Length / 1MB))

# ---------------------------------------------------------------- compilación
$common = @('/nologo', '/optimize+', '/platform:anycpu', '/target:winexe', "/win32icon:$ico", "/win32manifest:$(Join-Path $build 'app.manifest')",
            "/r:$fx\System.Windows.Forms.dll", "/r:$fx\System.dll")
$codeSkip = '^(Build|Dist|Datos|Exportaciones|Config|Tests|\.git|\.github|\.signpath|Eureka_CloudSpeed_Datos)\\'
$codeFiles = Get-ChildItem $root -Recurse -File -Force -Include *.ps1, *.psm1, *.xaml, *.cs, *.json | Where-Object { $_.FullName.Substring($root.Length + 1) -notmatch $codeSkip } | Sort-Object FullName
$manifest = Join-Path $obj 'manifest.txt'
$lines = foreach ($f in $codeFiles) { '{0} {1}' -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash, $f.FullName.Substring($root.Length + 1).Replace('\', '/') }
[IO.File]::WriteAllLines($manifest, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
Write-Host ("Lista de integridad: {0} archivos de código" -f @($lines).Count)
& $csc @common "/resource:$manifest,manifest.txt" "/out:$(Join-Path $root 'Eureka_CloudSpeed.exe')" (Join-Path $build 'Launcher.cs')
if ($LASTEXITCODE) { throw "Error compilando Eureka_CloudSpeed.exe ($LASTEXITCODE)" }
& $csc @common '/define:SINGLEFILE' "/r:$fx\System.IO.Compression.dll" "/r:$fx\System.IO.Compression.FileSystem.dll" "/resource:$payload,payload.zip" "/out:$(Join-Path $dist 'Eureka_CloudSpeed_Portable.exe')" (Join-Path $build 'Launcher.cs')
if ($LASTEXITCODE) { throw "Error compilando Eureka_CloudSpeed_Portable.exe ($LASTEXITCODE)" }

# ---------------------------------------------------------------- firma (opcional)
if ($CertificateThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $CertificateThumbprint } | Select-Object -First 1
    if (-not $cert) { throw "No se encuentra el certificado de firma de código $CertificateThumbprint" }
    foreach ($f in (Join-Path $root 'Eureka_CloudSpeed.exe'), (Join-Path $dist 'Eureka_CloudSpeed_Portable.exe')) {
        $sig = Set-AuthenticodeSignature -FilePath $f -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm SHA256
        Write-Host ("Firma de {0}: {1}" -f (Split-Path $f -Leaf), $sig.Status)
    }
}
else {
    Write-Warning 'Ejecutables sin firmar: Smart App Control puede bloquearlos y SmartScreen mostrará un aviso. Usa -CertificateThumbprint para firmarlos, o Eureka_CloudSpeed.cmd.'
}

# ---------------------------------------------------------------- ZIP de distribución (incluye Eureka_CloudSpeed.exe)
$files2 = Get-ChildItem $root -Recurse -File -Force | Where-Object { $_.FullName.Substring($root.Length + 1) -notmatch '^(\.git|Dist|Build\\obj|Datos|Exportaciones|Config|Eureka_CloudSpeed_Datos)(\\|$)|\.log$' }
New-CsZip (Join-Path $dist 'Eureka_CloudSpeed.zip') $files2 'Eureka_CloudSpeed/'

# ---------------------------------------------------------------- manifiesto de publicación (qué se publica en esta versión)
$version = ([regex]::Match((Get-Content (Join-Path $root 'Modules\Core.psm1') -Raw), "\`$script:Version = '([\d.]+)'")).Groups[1].Value
$artifacts = @(Get-Item (Join-Path $root 'Eureka_CloudSpeed.exe'), (Join-Path $dist 'Eureka_CloudSpeed_Portable.exe'), (Join-Path $dist 'Eureka_CloudSpeed.zip'))
$lines = @(
    "Eureka_CloudSpeed $version - manifiesto de publicación",
    "Fecha de compilación: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))",
    "Firma de código: $(if ($CertificateThumbprint) { "certificado $CertificateThumbprint" } else { 'SIN FIRMAR' })",
    '',
    'Artefactos (SHA-256):'
) + ($artifacts | ForEach-Object { '  {0}  {1,10:N0} bytes  {2}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Length, $_.Name }) + @(
    '',
    "Contenido del paquete ($(@($files2).Count) archivos, sin Datos, Exportaciones ni Config):"
) + ($files2 | Sort-Object FullName | ForEach-Object { '  ' + $_.FullName.Substring($root.Length + 1) })
$manifestOut = Join-Path $dist "MANIFIESTO-v$version.txt"
[IO.File]::WriteAllLines($manifestOut, [string[]]$lines, (New-Object Text.UTF8Encoding $true))
Write-Host "Manifiesto: $manifestOut"

Get-ChildItem (Join-Path $root 'Eureka_CloudSpeed.exe'), (Join-Path $dist '*') | Select-Object Name, @{ n = 'MB'; e = { '{0:N2}' -f ($_.Length / 1MB) } } | Format-Table -AutoSize

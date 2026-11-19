# Core.psm1 - Rutas, catálogo de regiones, preferencias y carga del motor en C#.

$script:Root = Split-Path $PSScriptRoot -Parent
$script:Version = '1.3.0'

function Get-CsRoot { $script:Root }
function Get-CsVersion { $script:Version }

function Get-CsDataRoot {
    # Ejecutable portable: los datos se guardan junto al .exe (CFG_DATA). Si no, en la carpeta de la herramienta.
    $d = if ($env:CFG_DATA) { $env:CFG_DATA } else { $script:Root }
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Get-CsFolder {
    param([ValidateSet('Datos', 'Exportaciones', 'Config')][string]$Name)
    $p = Join-Path (Get-CsDataRoot) $Name
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

# ------------------------------------------------------------------ motor C#

function Import-CsEngine {
    <# Compila Engine\*.cs en memoria con el compilador de .NET Framework incluido en Windows.
       No se guarda ninguna DLL en disco: Smart App Control / Control de aplicaciones bloquea las DLL
       sin firmar creadas por el usuario, y compilar en memoria tarda alrededor de 1 segundo. #>
    if ('CloudSpeed.ProbeEngine' -as [type]) { return }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.IO.Compression
    $src = Get-ChildItem (Join-Path $script:Root 'Engine') -Filter *.cs | Sort-Object Name
    $refs = @(
        [System.Windows.Window].Assembly.Location,           # PresentationFramework
        [System.Windows.Media.Brush].Assembly.Location,      # PresentationCore
        [System.Windows.DependencyObject].Assembly.Location, # WindowsBase
        [System.Xaml.XamlReader].Assembly.Location,          # System.Xaml
        [System.IO.Compression.ZipArchive].Assembly.Location,
        'System.dll', 'System.Core.dll', 'System.Xml.dll', 'System.Security.dll', 'System.Web.Extensions.dll'
    )
    Add-Type -Path $src.FullName -ReferencedAssemblies $refs -ErrorAction Stop
    # Limpia la caché de versiones anteriores, si existe
    $old = Join-Path $env:LOCALAPPDATA 'Eureka_CloudSpeed\cache'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ catálogo

function Get-CsCatalog {
    $file = Join-Path $script:Root 'Catalog\regions.json'
    $cat = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = New-Object 'System.Collections.Generic.List[CloudSpeed.RegionInfo]'
    foreach ($r in $cat.regions) {
        $cloud = $cat.clouds.($r.cloud)
        $hostName = if ($r.PSObject.Properties['host']) { [string]$r.host } else { $cloud.hostPattern -replace '\{code\}', $r.code }
        $ri = New-Object CloudSpeed.RegionInfo
        $ri.Cloud = $r.cloud; $ri.Code = $r.code; $ri.Name = $r.name; $ri.Geo = $r.geo; $ri.Country = $r.country; $ri.City = $r.city
        $ri.Lat = [double]$r.lat; $ri.Lon = [double]$r.lon; $ri.Host = $hostName.Trim(); $ri.Port = [int]$cloud.port
        $ri.Note = if ($r.PSObject.Properties['note']) { $r.note } else { $null }
        $list.Add($ri)
    }
    $colors = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $methods = @{}
    foreach ($p in $cat.clouds.PSObject.Properties) { $colors[$p.Name] = $p.Value.color; $methods[$p.Name] = $p.Value.method }
    [pscustomobject]@{
        Regions     = $list
        Clouds      = [string[]]@($cat.clouds.PSObject.Properties.Name)
        CloudColors = $colors
        Methods     = $methods
        Geos        = [string[]]@($cat.geographies)
    }
}

# ------------------------------------------------------------------ preferencias

function Get-CsPrefs {
    $p = Join-Path (Get-CsFolder Config) 'preferencias.json'
    $def = [ordered]@{ Theme = 'System'; Samples = 5; Tls = $false; Continuous = $false; Interval = 60; Label = ''; Clouds = @('Azure', 'AWS'); Geos = @(); SaveHistory = $true; Anonymize = $false; RetentionMonths = 12 }
    if (Test-Path $p) {
        try {
            $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($def.Keys)) { if ($j.PSObject.Properties[$k]) { $def[$k] = $j.$k } }
        }
        catch { }
    }
    return [pscustomobject]$def
}

function Save-CsPrefs {
    param($Prefs)
    try { $Prefs | ConvertTo-Json -Depth 4 | Set-Content (Join-Path (Get-CsFolder Config) 'preferencias.json') -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------ confidencialidad

# Secretos (URL con SAS o firmas de S3) cifrados con DPAPI: solo el mismo usuario de Windows en el mismo
# equipo puede descifrarlos. Formato en disco: "dpapi:<base64>".
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('Eureka_CloudSpeed/velocidad/v1')
Add-Type -AssemblyName System.Security

function Protect-CsSecret([string]$Text) {
    if (-not $Text -or $Text.StartsWith('dpapi:')) { return $Text }
    $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $script:Entropy, 'CurrentUser')
    return 'dpapi:' + [Convert]::ToBase64String($b)
}

function Unprotect-CsSecret([string]$Text) {
    if (-not $Text -or -not $Text.StartsWith('dpapi:')) { return $Text }
    $b = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text.Substring(6)), $script:Entropy, 'CurrentUser')
    return [Text.Encoding]::UTF8.GetString($b)
}

function Test-CsSecretUrl([string]$Url) {
    # URL que lleva credenciales: SAS de Azure (sig=) o firma de S3 (X-Amz-Signature / Signature=)
    return [bool]($Url -match '[?&](sig|X-Amz-Signature|Signature)=')
}

# Seudónimo del equipo: el nombre real no sale en exportaciones ni en el histórico si está activado
$script:Anonymize = $false
function Set-CsAnonymize([bool]$On) { $script:Anonymize = $On }
function Get-CsMachine {
    if (-not $script:Anonymize) { return $env:COMPUTERNAME }
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("Eureka_CloudSpeed|$env:COMPUTERNAME|$env:USERNAME"))) -replace '-', ''
    return 'Equipo-' + $h.Substring(0, 8)
}

# ------------------------------------------------------------------ conservación de datos (RGPD, art. 5.1.e)

$script:HistoryFiles = @(
    @{ File = 'Mediciones.csv'; Column = 'FechaHora'; Delimiter = ',' }
    @{ File = 'Sesiones.csv'; Column = 'Inicio'; Delimiter = ',' }
    @{ File = 'Velocidad.csv'; Column = 'Fecha'; Delimiter = ';' }
    @{ File = 'Estado.csv'; Column = 'Fecha'; Delimiter = ';' }
)

function Invoke-CsRetention {
    <# Borra del histórico las filas con más de $Months meses. 0 = conservar sin límite. Devuelve las filas borradas. #>
    param([int]$Months = 12)
    if ($Months -le 0) { return 0 }
    $limit = (Get-Date).AddMonths(-$Months)
    $removed = 0
    foreach ($h in $script:HistoryFiles) {
        $p = Join-Path (Get-CsFolder Datos) $h.File
        if (-not (Test-Path $p)) { continue }
        try {
            $rows = @(Import-Csv $p -Delimiter $h.Delimiter -Encoding UTF8)
            $keep = @($rows | Where-Object { $d = [datetime]::MinValue; -not [datetime]::TryParse([string]$_.($h.Column), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d) -or $d -ge $limit })
            if ($keep.Count -lt $rows.Count) {
                $removed += $rows.Count - $keep.Count
                $tmp = "$p.tmp"
                if ($keep.Count) { $keep | Export-Csv $tmp -NoTypeInformation -Encoding UTF8 -Delimiter $h.Delimiter } else { Set-Content $tmp -Value '' -Encoding UTF8 }
                Move-Item $tmp $p -Force
            }
        }
        catch { }
    }
    return $removed
}

function Remove-CsHistory {
    <# Borra todo el histórico y las cachés descargadas (no toca Exportaciones ni la configuración). #>
    $n = 0
    foreach ($h in $script:HistoryFiles) { $p = Join-Path (Get-CsFolder Datos) $h.File; if (Test-Path $p) { Remove-Item $p -Force; $n++ } }
    $c = Join-Path (Get-CsFolder Datos) 'cache'
    if (Test-Path $c) { Remove-Item $c -Recurse -Force; $n++ }
    return $n
}

Export-ModuleMember -Function *-Cs*

<#
.SYNOPSIS
    Eureka_CloudSpeed - mide la latencia desde este equipo a las regiones de Azure y AWS.
.DESCRIPTION
    Sin parámetros abre la interfaz gráfica. Con -SinInterfaz mide desde la consola (útil en tareas
    programadas para alimentar el histórico de Power BI) y puede exportar los resultados.
    No necesita permisos de administrador.
.EXAMPLE
    .\Eureka_CloudSpeed.ps1
.EXAMPLE
    .\Eureka_CloudSpeed.ps1 -SinInterfaz -Nube Azure,AWS -Geografia Europa -Muestras 5 -Exportar Excel,Html
.EXAMPLE
    .\Eureka_CloudSpeed.ps1 -SinInterfaz -Etiqueta "Oficina" -Rondas 3 -Intervalo 60
#>
[CmdletBinding()]
param(
    [switch]$SinInterfaz,
    [string[]]$Nube,
    [string[]]$Geografia,
    [string[]]$Region,
    [ValidateRange(1, 50)][int]$Muestras = 5,
    [ValidateRange(1, 1000)][int]$Rondas = 1,
    [ValidateRange(5, 86400)][int]$Intervalo = 60,
    [switch]$Tls,
    [string]$Etiqueta = '',
    [string[]]$Exportar,
    [switch]$SinHistorico,
    [switch]$Anonimo,
    [switch]$IniciarMedicion,
    [switch]$OcultarConsola
)
$ErrorActionPreference = 'Stop'
# Con -File (o desde el .cmd) las listas llegan como "a,b": se separan aquí
function Split-CsList([string[]]$v) { if ($v) { @($v | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
$Nube = Split-CsList $Nube; $Geografia = Split-CsList $Geografia; $Region = Split-CsList $Region; $Exportar = Split-CsList $Exportar
$bad = @($Exportar | Where-Object { $_ -notin 'Excel', 'Csv', 'Html', 'PowerBI' })
if ($bad) { Write-Error ("Formato de exportación no válido: {0}. Usa Excel, Csv, Html o PowerBI." -f ($bad -join ', ')); exit 1 }
$root = $PSScriptRoot
Import-Module (Join-Path $root 'Modules\Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules\Export.psm1') -Force -DisableNameChecking

try { Import-CsEngine }
catch {
    $msg = "No se pudo cargar el motor de medición (Engine\*.cs):`n$($_.Exception.Message)"
    if ($SinInterfaz) { Write-Error $msg; exit 2 }
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show($msg, 'Eureka_CloudSpeed', 'OK', 'Error'); exit 2
}
$catalog = Get-CsCatalog
Set-CsAnonymize ([bool]$Anonimo -or [bool](Get-CsPrefs).Anonymize)
# Conservación (RGPD): se borra del histórico lo que supere el plazo elegido (12 meses por defecto)
try { $script:Purged = Invoke-CsRetention ([int](Get-CsPrefs).RetentionMonths) } catch { $script:Purged = 0 }

if (-not $SinInterfaz) {
    if ($OcultarConsola) {
        try {
            Add-Type -Name Win -Namespace CsConsole -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
            [void][CsConsole.Win]::ShowWindow([CsConsole.Win]::GetConsoleWindow(), 0)
        }
        catch { }
    }
    . (Join-Path $root 'UI\Gui.ps1')
    . (Join-Path $root 'UI\Shell.ps1')
    foreach ($f in (Get-ChildItem (Join-Path $root 'UI\Pages') -Filter *.ps1)) { . $f.FullName }
    $prefs = Get-CsPrefs
    if ($Nube) { $prefs.Clouds = $Nube }
    if ($Geografia) { $prefs.Geos = $Geografia }
    $script:AutoStart = [bool]$IniciarMedicion
    Show-CsGui -Catalog $catalog -Prefs $prefs
    exit 0
}

# ------------------------------------------------------------------ modo consola
$sel = @($catalog.Regions | Where-Object {
        $_.HasEndpoint -and
        (-not $Nube -or $Nube -contains $_.Cloud) -and
        (-not $Geografia -or $Geografia -contains $_.Geo) -and
        (-not $Region -or $Region -contains $_.Code)
    })
if ($sel.Count -eq 0) { Write-Error 'Ninguna región coincide con los filtros.'; exit 1 }

$rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[CloudSpeed.RegionRow]'
$map = @{}
foreach ($r in $catalog.Regions) { $row = New-Object CloudSpeed.RegionRow $r, $catalog.CloudColors[$r.Cloud]; $rows.Add($row); $map[$r.Key] = $row }
$engine = New-Object CloudSpeed.ProbeEngine
$engine.Samples = $Muestras; $engine.MeasureTls = [bool]$Tls; $engine.Parallel = 16; $engine.GapMs = 100
$data = Get-CsFolder Datos
$start = Get-Date
Write-Host ("Eureka_CloudSpeed {0} · {1} regiones · {2} muestras · {3} ronda(s) · sesión {4}" -f (Get-CsVersion), $sel.Count, $Muestras, $Rondas, $engine.SessionId) -ForegroundColor Cyan

for ($round = 1; $round -le $Rondas; $round++) {
    $t0 = Get-Date
    $progress = [Action[int, int]] { param($d, $t) Write-Progress -Activity "Ronda $round de $Rondas" -Status "$d / $t muestras" -PercentComplete ([math]::Min(100, 100 * $d / [math]::Max(1, $t))) }
    $samples = [CloudSpeed.Runner]::RunBlocking($engine, [CloudSpeed.RegionInfo[]]$sel, $round, $progress)
    Write-Progress -Activity "Ronda $round" -Completed
    foreach ($s in $samples) { $map[$s.Region.Key].Add($s) }
    if (-not $SinHistorico) {
        if ($round -eq 1) {
            [CloudSpeed.Store]::AppendSession((Join-Path $data 'Sesiones.csv'), $engine.SessionId, $start, (Get-CsMachine), $Etiqueta, $Muestras, [bool]$Tls, (Get-CsVersion))
            [CloudSpeed.Store]::WriteRegions((Join-Path $data 'Regiones.csv'), $catalog.Regions)
        }
        [CloudSpeed.Store]::AppendSamples((Join-Path $data 'Mediciones.csv'), $samples, (Get-CsMachine), $Etiqueta)
    }
    Write-Host ("Ronda {0}: {1} muestras en {2:0.0} s" -f $round, $samples.Count, ((Get-Date) - $t0).TotalSeconds)
    if ($round -lt $Rondas) {
        $wait = $t0.AddSeconds($Intervalo) - (Get-Date)
        if ($wait.TotalMilliseconds -gt 0) { Start-Sleep -Milliseconds ([int]$wait.TotalMilliseconds) }
    }
}
foreach ($r in $rows) { $r.Recompute() }
[CloudSpeed.RowTools]::SortInPlace($rows)

$rows | Where-Object { $_.Count -gt 0 } | Select-Object -First 25 Rank, Cloud, @{ n = 'Región'; e = { $_.Name } }, Code,
    @{ n = 'P50'; e = { $_.P50 } }, @{ n = 'P95'; e = { $_.P95 } }, @{ n = 'Jitter'; e = { $_.Jitter } }, @{ n = 'Pérdida'; e = { '{0:P0}' -f $_.Loss } } | Format-Table -AutoSize

if ($Exportar) {
    $meta = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
    foreach ($kv in @(
            @('Fecha', (Get-Date).ToString('dd/MM/yyyy HH:mm')), @('Equipo', (Get-CsMachine)), @('Etiqueta', $(if ($Etiqueta) { $Etiqueta } else { '(sin etiqueta)' })),
            @('Sesión', $engine.SessionId), @('Rondas', $Rondas), @('Muestras por región y ronda', $Muestras))) {
        $meta.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' $kv[0], ([string]$kv[1])))
    }
    foreach ($x in $Exportar) {
        $f = switch ($x) {
            'Excel' { Export-CsExcel -Rows $rows -Catalog $catalog -Meta $meta -Label $Etiqueta }
            'Csv' { Export-CsCsv -Rows $rows -Label $Etiqueta }
            'Html' { Export-CsHtml -Rows $rows -Catalog $catalog -Meta $meta }
            'PowerBI' { (Export-CsPowerBI -Catalog $catalog).Workbook }
        }
        Write-Host "$x -> $f" -ForegroundColor Green
    }
}
exit 0

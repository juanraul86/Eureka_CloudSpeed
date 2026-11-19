# Shell.ps1 - Armazón de la interfaz: carga de páginas bajo demanda, tareas en segundo plano
# (consultas web sin congelar la ventana) y utilidades comunes.

function Import-CsXaml([string]$Path) {
    [xml]$x = Get-Content $Path -Raw -Encoding UTF8
    $root = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    foreach ($n in $x.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $n.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -First 1 -ExpandProperty Value
        $el = $root.FindName($name)
        if ($null -ne $el) { $script:Ui[$name] = $el }
    }
    return $root
}

function Get-CsLand {
    $list = New-Object 'System.Collections.Generic.List[double[]]'
    try {
        $j = Get-Content (Join-Path (Get-CsRoot) 'Catalog\world-land.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.polygons) { $list.Add([double[]]$p) }
    }
    catch { }
    , $list
}

function Get-CsJson([string]$Name) {
    Get-Content (Join-Path (Get-CsRoot) "Catalog\$Name") -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ------------------------------------------------------------------ páginas

$script:PageInit = @{}

function Show-CsPage([string]$Tag) {
    if (-not $Tag) { return }
    if (-not $script:Pages.ContainsKey($Tag)) {
        try {
            $root = Import-CsXaml (Join-Path (Get-CsRoot) "UI\Pages\$Tag.xaml")
            $script:Pages[$Tag] = $root
            [void]$script:Ui.PageHost.Children.Add($root)
        }
        catch { Show-CsMessage ("No se pudo abrir la sección {0}:`n{1}" -f $Tag, $_.Exception.Message) 'Error'; return }
    }
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visibility = $(if ($k -eq $Tag) { 'Visible' } else { 'Collapsed' }) }
    $script:G.Page = $Tag
    if (-not $script:PageInit[$Tag]) {
        $script:PageInit[$Tag] = $true
        $fn = "Initialize-CsPage$Tag"
        if (Get-Command $fn -ErrorAction SilentlyContinue) {
            try { & $fn } catch { Show-CsMessage ("Error al preparar la sección {0}:`n{1}" -f $Tag, $_.Exception.Message) 'Error' }
        }
    }
    $fn = "Show-CsPage$Tag"
    if (Get-Command $fn -ErrorAction SilentlyContinue) { try { & $fn } catch { Set-CsStatus $_.Exception.Message } }
    $script:G.PagesDirty = $true
}

function Invoke-CsPagesTick {
    if (Get-Command Invoke-CsStatusAuto -ErrorAction SilentlyContinue) { Invoke-CsStatusAuto }
    $p = $script:G.Page
    if (-not $p -or $p -eq 'Latencia') { return }
    $fn = "Update-CsPage$p"
    if (Get-Command $fn -ErrorAction SilentlyContinue) { & $fn }
}

function Stop-CsPages {
    foreach ($k in @($script:PageInit.Keys)) {
        $fn = "Stop-CsPage$k"
        if (Get-Command $fn -ErrorAction SilentlyContinue) { try { & $fn } catch { } }
    }
    foreach ($j in @($script:Jobs)) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
}

# ------------------------------------------------------------------ tareas en segundo plano

$script:Jobs = New-Object System.Collections.ArrayList

function Start-CsJob {
    <# Ejecuta $Script en otro runspace con $Arguments. Al terminar llama a $OnDone con (resultado, error)
       en el hilo de la interfaz. $Progress (hashtable sincronizada) permite informar del avance. #>
    param([scriptblock]$Script, [object[]]$Arguments = @(), [scriptblock]$OnDone, [string]$Status)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $job = @{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Started = Get-Date }
    [void]$script:Jobs.Add($job)
    if ($Status) { Set-CsStatus $Status }
    return $job
}

function Invoke-CsJobsTick {
    if ($script:Jobs.Count -eq 0) { return }
    foreach ($j in @($script:Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        $script:Jobs.Remove($j)
        $result = $null; $err = $null
        try {
            $result = $j.PS.EndInvoke($j.Handle)
            if ($j.PS.Streams.Error.Count -gt 0) { $err = $j.PS.Streams.Error[0].Exception.Message }
        }
        catch { $err = $_.Exception.InnerException.Message; if (-not $err) { $err = $_.Exception.Message } }
        finally { $j.PS.Dispose() }
        if ($j.OnDone) {
            try { & $j.OnDone $result $err }
            catch { Set-CsStatus ("Error: " + $_.Exception.Message) }
        }
    }
}

# ------------------------------------------------------------------ utilidades

function Copy-CsText([string]$Text, [string]$What = 'Texto') {
    try { [System.Windows.Clipboard]::SetText($Text); Set-CsStatus "$What copiado al portapapeles." } catch { Set-CsStatus 'No se pudo copiar al portapapeles.' }
}

function Save-CsFileDialog([string]$Name, [string]$Filter = 'CSV (*.csv)|*.csv') {
    $d = New-Object Microsoft.Win32.SaveFileDialog
    $d.InitialDirectory = Get-CsFolder Exportaciones
    $d.FileName = $Name; $d.Filter = $Filter
    if ($d.ShowDialog($script:Ui.Window)) { return $d.FileName }
    return $null
}

function Export-CsObjects($Objects, [string]$Name) {
    if (-not $Objects -or @($Objects).Count -eq 0) { Show-CsMessage 'No hay datos que exportar.' 'Warning'; return }
    $f = Save-CsFileDialog $Name
    if (-not $f) { return }
    # Evita la inyección de fórmulas: un texto que empiece por = + - @ se exporta precedido de '
    $safe = foreach ($o in @($Objects)) {
        $c = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [string] -and $v.Length -gt 0 -and '=+-@' + "`t`r" -match [regex]::Escape($v[0])) { $v = "'" + $v }
            $c[$p.Name] = $v
        }
        [pscustomobject]$c
    }
    # Punto y coma: Excel en español lo abre directamente en columnas
    @($safe) | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Set-CsStatus "Exportado: $f"
    Start-Process explorer.exe "/select,`"$f`""
}

function Get-CsCacheFolder {
    $d = Join-Path (Get-CsFolder Datos) 'cache'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function New-CsItem([string]$Text, $Tag) {
    $i = New-Object System.Windows.Controls.ComboBoxItem
    $i.Content = $Text; $i.Tag = $Tag
    return $i
}

# ------------------------------------------------------------------ latencia: prueba rápida y tu conexión

function Start-CsQuickTest {
    if ($script:G.Running -or $script:G.NextRound) { return }
    $script:G.QuickLeft = 10
    $script:G.StopRequested = $false
    if (-not (Start-CsRound)) { $script:G.QuickLeft = 0 }
}

function Show-CsConnection {
    $script:Ui.BtnConn.IsEnabled = $false
    $script:Ui.TxtConn.Text = 'Consultando…'
    [void](Start-CsJob -Status 'Consultando tu conexión en ipinfo.io…' -Script {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 10 -UseBasicParsing
        } -OnDone {
            param($r, $err)
            $script:Ui.BtnConn.IsEnabled = $true
            if ($err -or -not $r) { $script:Ui.TxtConn.Text = "No se pudo consultar: $err"; return }
            $x = @($r)[0]
            $script:Ui.TxtConn.Text = "IP pública: $($x.ip)`nUbicación: $($x.city), $($x.region) ($($x.country))`nOperador: $($x.org)"
            Set-CsStatus 'Conexión consultada.'
        })
}

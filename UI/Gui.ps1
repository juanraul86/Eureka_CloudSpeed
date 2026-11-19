# Gui.ps1 - Interfaz WPF de Eureka_CloudSpeed (modo claro/oscuro).
# Las mediciones corren en el motor C# (grupo de subprocesos); un temporizador de la interfaz recoge
# los resultados de una cola concurrente cada 150 ms, así la ventana nunca se congela.

$script:Palettes = @{
    Light = @{
        Bg = '#F3F4F6'; Surface = '#FFFFFF'; SurfaceAlt = '#F9FAFB'; Border = '#E5E7EB'; BorderStrong = '#D1D5DB'
        Text = '#1F2937'; TextMuted = '#6B7280'; Accent = '#0F6CBD'; AccentText = '#FFFFFF'; Header = '#0F6CBD'
        HeaderSub = '#D6E6F7'; HeaderPill = '#0B5A9E'; Danger = '#B42318'; DangerBorder = '#F4B4AE'; Hover = '#E6EEF7'
        Selection = '#DCE8F5'; Input = '#FFFFFF'; Grid = '#E5E7EB'; CodeBg = '#F3F4F6'; Nav = '#FFFFFF'
    }
    Dark  = @{
        Bg = '#111318'; Surface = '#1B1E25'; SurfaceAlt = '#20242C'; Border = '#2D323C'; BorderStrong = '#3D4350'
        Text = '#E6E8EC'; TextMuted = '#9AA3B2'; Accent = '#3B8EE0'; AccentText = '#FFFFFF'; Header = '#15233A'
        HeaderSub = '#A9BCD6'; HeaderPill = '#24406A'; Danger = '#F97066'; DangerBorder = '#7A2E2A'; Hover = '#263042'
        Selection = '#24364F'; Input = '#14171D'; Grid = '#2D323C'; CodeBg = '#14171D'; Nav = '#1B1E25'
    }
}

# ------------------------------------------------------------------ utilidades

function Get-CsBrush([string]$Hex) {
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze(); return $b
}

function Set-CsStatus([string]$Text) { $script:Ui.TxtStatus.Text = $Text }

function Show-CsMessage([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($script:Ui.Window, $Text, 'Eureka_CloudSpeed', 'OK', $Icon)
}

function Test-CsSystemDark {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    return ($v -eq 0)
}

function Set-CsTheme([string]$Mode = 'System') {
    $effective = $Mode
    if ($Mode -eq 'System') { $effective = $(if (Test-CsSystemDark) { 'Dark' } else { 'Light' }) }
    $pal = $script:Palettes[$effective]
    $res = [System.Windows.Application]::Current.Resources
    foreach ($k in $pal.Keys) {
        if ($res.Contains($k)) { $res.Remove($k) }
        $res.Add($k, (Get-CsBrush $pal[$k]))
    }
    $script:G.Theme = $Mode
    $t = New-Object CloudSpeed.ChartTheme
    $t.Text = Get-CsBrush $pal.Text; $t.Muted = Get-CsBrush $pal.TextMuted; $t.Grid = Get-CsBrush $pal.Grid; $t.Surface = Get-CsBrush $pal.Surface
    foreach ($c in $script:Cat.CloudColors.Keys) { $t.CloudBrushes[$c] = Get-CsBrush $script:Cat.CloudColors[$c] }
    $script:G.ChartTheme = $t
    $script:Ui.BtnTheme.Content = @{ System = 'Tema: sistema'; Light = 'Tema: claro'; Dark = 'Tema: oscuro' }[$Mode]
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:Ui.Window).Handle
        if ($h -ne [IntPtr]::Zero) { [CloudSpeed.Native]::DarkTitleBar($h, ($effective -eq 'Dark')) }
    }
    catch { }
    $script:G.ChartsDirty = $true
    $script:G.PagesDirty = $true
}

# ------------------------------------------------------------------ filtros y selección

function Update-CsFilter {
    $clouds = @($script:CloudBoxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $geos = @($script:GeoBoxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $q = $script:Ui.TxtSearch.Text.Trim()
    foreach ($r in $script:Rows) {
        $ok = ($clouds -contains $r.Cloud) -and ($geos -contains $r.Geo)
        if ($ok -and $q) {
            $i = $r.Info
            $ok = ($i.Name, $i.Code, $i.City, $i.Country, $i.Geo | Where-Object { $_ -and $_.IndexOf($q, [StringComparison]::CurrentCultureIgnoreCase) -ge 0 }).Count -gt 0
        }
        $r.Visible = $ok
    }
    $script:View.Refresh()
    Update-CsSelectionCount
    $script:G.ChartsDirty = $true
}

function Get-CsTargets { @($script:Rows | Where-Object { $_.Visible -and $_.Selected -and $_.HasEndpoint }) }

function Update-CsSelectionCount {
    $vis = @($script:Rows | Where-Object Visible)
    $sel = @(Get-CsTargets).Count
    $noEp = @($vis | Where-Object { -not $_.HasEndpoint }).Count
    $txt = "$sel de $($vis.Count) regiones marcadas para medir."
    if ($noEp) { $txt += " $noEp sin endpoint público (ver catálogo)." }
    $script:Ui.TxtSelCount.Text = $txt
}

# ------------------------------------------------------------------ medición

function Start-CsRound {
    $targets = Get-CsTargets
    if ($targets.Count -eq 0) { Show-CsMessage 'No hay ninguna región marcada con los filtros actuales.' 'Warning'; return $false }
    $e = $script:Engine
    $e.Samples = $(if ($script:G.QuickLeft -gt 0) { 1 } else { [int]$script:Ui.SldSamples.Value })
    $e.MeasureTls = [bool]$script:Ui.ChkTls.IsChecked
    $script:G.Round++
    $script:G.RoundStart = Get-Date
    $script:G.RoundSamples = New-Object 'System.Collections.Generic.List[CloudSpeed.Sample]'
    $script:G.RoundCount = @{}
    $script:G.Label = $script:Ui.TxtLabel.Text.Trim()
    if (-not $script:G.SessionStart) { $script:G.SessionStart = Get-Date }
    $e.Start([CloudSpeed.RegionInfo[]]@($targets | ForEach-Object { $_.Info }), $script:G.Round)
    $script:G.Running = $true
    $script:G.NextRound = $null
    Set-CsRunningUi $true
    Set-CsStatus ("Ronda {0}: midiendo {1} regiones ({2} muestras cada una)…" -f $script:G.Round, $targets.Count, $e.Samples)
    return $true
}

function Set-CsRunningUi([bool]$Running) {
    $busy = $Running -or ($null -ne $script:G.NextRound)
    $script:Ui.BtnStart.IsEnabled = -not $busy
    $script:Ui.BtnStop.IsEnabled = $busy
    $script:Ui.BtnReset.IsEnabled = -not $busy
    $script:Ui.SldSamples.IsEnabled = -not $Running
    $script:Ui.ChkTls.IsEnabled = -not $Running
}

function Stop-CsMeasure {
    $script:G.StopRequested = $true
    $script:G.NextRound = $null
    $script:G.QuickLeft = 0
    $script:Engine.Cancel()
    if (-not $script:Engine.IsRunning) { $script:G.Running = $false; Set-CsRunningUi $false; Set-CsStatus 'Medición detenida.' }
    else { Set-CsStatus 'Deteniendo…' }
}

function Complete-CsRound {
    $script:G.Running = $false
    foreach ($r in $script:Rows) { $r.Measuring = $false }
    $n = $script:G.RoundSamples.Count
    if ($n -gt 0 -and $script:Ui.ChkHistory.IsChecked) { Save-CsHistory $script:G.RoundSamples }
    $ok = @($script:G.RoundSamples | Where-Object Ok).Count
    $msg = "Ronda {0} terminada en {1:0.0} s: {2} muestras, {3} sin respuesta." -f $script:G.Round, ((Get-Date) - $script:G.RoundStart).TotalSeconds, $n, ($n - $ok)
    if ($script:G.QuickLeft -gt 0 -and -not $script:G.StopRequested) {
        $script:G.QuickLeft--
        if ($script:G.QuickLeft -gt 0) { $script:G.NextRound = (Get-Date).AddMilliseconds(300); $msg += " Prueba rápida: quedan $($script:G.QuickLeft) rondas." }
        else { $msg += ' Prueba rápida terminada.' }
    }
    elseif ($script:Ui.ChkContinuous.IsChecked -and -not $script:G.StopRequested) {
        $script:G.NextRound = $script:G.RoundStart.AddSeconds([int]$script:Ui.SldInterval.Value)
        if ($script:G.NextRound -lt (Get-Date)) { $script:G.NextRound = (Get-Date).AddSeconds(1) }
        $msg += " Siguiente ronda a las {0:HH:mm:ss}." -f $script:G.NextRound
    }
    $script:G.StopRequested = $false
    Set-CsRunningUi $false
    Set-CsStatus $msg
}

function Save-CsHistory($Samples) {
    try {
        $d = Get-CsFolder Datos
        if (-not $script:G.SessionLogged) {
            [CloudSpeed.Store]::AppendSession((Join-Path $d 'Sesiones.csv'), $script:Engine.SessionId, $script:G.SessionStart, (Get-CsMachine),
                $script:G.Label, $script:Engine.Samples, $script:Engine.MeasureTls, (Get-CsVersion))
            [CloudSpeed.Store]::WriteRegions((Join-Path $d 'Regiones.csv'), $script:Cat.Regions)
            $script:G.SessionLogged = $true
        }
        [CloudSpeed.Store]::AppendSamples((Join-Path $d 'Mediciones.csv'), $Samples, (Get-CsMachine), $script:G.Label)
    }
    catch { Set-CsStatus ("No se pudo guardar el histórico: " + $_.Exception.Message) }
}

function Reset-CsResults {
    foreach ($r in $script:Rows) { $r.Clear() }
    $script:Engine.NewSession()
    $script:G.Round = 0; $script:G.SessionStart = $null; $script:G.SessionLogged = $false
    [CloudSpeed.RowTools]::SortInPlace($script:Rows)
    Update-CsCards
    $script:Ui.Progress.Value = 0
    $script:G.ChartsDirty = $true
    Set-CsStatus 'Resultados borrados. La próxima medición empieza una sesión nueva.'
}

# ------------------------------------------------------------------ refresco periódico

function Update-CsCards {
    $es = [Globalization.CultureInfo]'es-ES'
    foreach ($c in 'Azure', 'AWS') {
        $best = $script:Rows | Where-Object { $_.Cloud -eq $c -and $null -ne $_.P50 } | Sort-Object SortKey | Select-Object -First 1
        $val = $script:Ui.("Card$($c -replace 'AWS','Aws')")
        $sub = $script:Ui.("Card$($c -replace 'AWS','Aws')Sub")
        if ($best) { $val.Text = $best.P50.ToString('0.0', $es) + ' ms'; $sub.Text = "$($best.Name) · $($best.Info.City)" }
        else { $val.Text = '—'; $sub.Text = ' ' }
    }
    $measured = @($script:Rows | Where-Object { $_.Count -gt 0 })
    $script:Ui.CardRegions.Text = $measured.Count
    $fail = @($measured | Where-Object { $_.OkCount -eq 0 }).Count
    $script:Ui.CardRegionsSub.Text = $(if ($fail) { "$fail sin respuesta" } elseif ($measured.Count) { 'todas responden' } else { ' ' })
    $tot = ($measured | Measure-Object Count -Sum).Sum
    $script:Ui.CardSamples.Text = [int]$tot
    $script:Ui.CardSamplesSub.Text = $(if ($script:G.Round) { "$($script:G.Round) ronda(s) · sesión $($script:Engine.SessionId)" } else { ' ' })
}

function Invoke-CsTick {
    $e = $script:Engine
    $changed = New-Object 'System.Collections.Generic.HashSet[CloudSpeed.RegionRow]'
    $k = $null
    while ($e.Started.TryDequeue([ref]$k)) { $script:Map[$k].Measuring = $true }
    $s = $null
    while ($e.Queue.TryDequeue([ref]$s)) {
        $row = $script:Map[$s.Region.Key]
        $row.Add($s); [void]$changed.Add($row)
        $script:G.RoundSamples.Add($s)
        $script:G.RoundCount[$row.Info.Key] = 1 + [int]$script:G.RoundCount[$row.Info.Key]
        if ($script:G.RoundCount[$row.Info.Key] -ge $e.Samples) { $row.Measuring = $false }
    }
    if ($changed.Count -gt 0) {
        foreach ($r in $changed) { $r.Recompute() }
        [CloudSpeed.RowTools]::SortInPlace($script:Rows)
        $max = ($script:Rows | Where-Object { $null -ne $_.P50 } | Measure-Object P50 -Maximum).Maximum
        foreach ($r in $script:Rows) { $r.SetScale([double]$max, 80) }
        Update-CsCards
        $script:G.ChartsDirty = $true
    }
    if ($script:G.Running) {
        if ($e.Total -gt 0) { $script:Ui.Progress.Value = $e.Done / $e.Total }
        if (-not $e.IsRunning -and $e.Queue.IsEmpty) { Complete-CsRound }
    }
    elseif ($script:G.NextRound) {
        $left = ($script:G.NextRound - (Get-Date)).TotalSeconds
        if ($left -le 0) { [void](Start-CsRound) }
        else {
            $script:Ui.Progress.Value = $(if ($script:G.QuickLeft -gt 0) { 1 } else { 1 - $left / [math]::Max(1, [int]$script:Ui.SldInterval.Value) })
            $script:Ui.BtnStop.IsEnabled = $true
        }
    }
    if ($script:G.ChartsDirty -and ((Get-Date) - $script:G.LastDraw).TotalMilliseconds -gt 450) { Update-CsCharts }
}

function Update-CsCharts {
    $script:G.ChartsDirty = $false
    $script:G.LastDraw = Get-Date
    $th = $script:G.ChartTheme
    $vis = [CloudSpeed.RegionRow[]]@($script:Rows | Where-Object Visible)
    switch ($script:Ui.Tabs.SelectedIndex) {
        1 {
            $w = $script:Ui.ScrollBars.ViewportWidth - 34
            [CloudSpeed.Charts]::Bars($script:Ui.CanvasBars, $vis, $th, $w, [math]::Max(200, $script:Ui.ScrollBars.ViewportHeight - 26), 120)
        }
        2 {
            $sel = $script:Ui.Grid.SelectedItem
            $top = @($vis | Where-Object { $null -ne $_.P50 } | Select-Object -First 6)
            if ($sel -and $null -ne $sel.P50 -and $top -notcontains $sel) { $top = @($sel) + @($top | Select-Object -First 5) }
            [CloudSpeed.Charts]::Lines($script:Ui.CanvasLines, [CloudSpeed.RegionRow[]]$top, $th, $script:Ui.HostLines.ActualWidth, $script:Ui.HostLines.ActualHeight)
        }
        3 {
            $pts = New-Object 'System.Collections.Generic.List[CloudSpeed.MapPoint]'
            foreach ($r in $vis) {
                $p = New-Object CloudSpeed.MapPoint
                $p.Lon = $r.Info.Lon; $p.Lat = $r.Info.Lat; $p.Tag = $r
                $p.Label = $r.Label
                if ($null -ne $r.P50) { $p.Color = $r.LevelColor; $p.Size = 12; $p.Tip = '{0}{1}{2:0.0} ms · {3}' -f $r.Label, [Environment]::NewLine, $r.P50, $r.City }
                else { $p.Color = $r.CloudColor; $p.Size = 7; $p.Hollow = $true; $p.Tip = "$($r.Label)$([Environment]::NewLine)sin medir" }
                $pts.Add($p)
            }
            [CloudSpeed.Charts]::Map($script:Ui.CanvasMap, $script:Land, $pts, $th, $script:Ui.HostMap.ActualWidth, $script:Ui.HostMap.ActualHeight, -170, 190, -58, 78, $false, $null)
        }
        4 {
            $clouds = [string[]]@($script:CloudBoxes | Where-Object IsChecked | ForEach-Object Tag)
            [CloudSpeed.Charts]::GeoCompare($script:Ui.CanvasGeo, $vis, $script:Cat.Geos, $clouds, $th, $script:Ui.HostGeo.ActualWidth, $script:Ui.HostGeo.ActualHeight)
        }
    }
}

# ------------------------------------------------------------------ exportación

function Get-CsSessionMeta {
    $m = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
    $add = { param($k, $v) $m.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' $k, ([string]$v))) }
    & $add 'Fecha' ((Get-Date).ToString('dd/MM/yyyy HH:mm'))
    & $add 'Equipo' (Get-CsMachine)
    & $add 'Etiqueta' $(if ($script:G.Label) { $script:G.Label } else { '(sin etiqueta)' })
    & $add 'Sesión' $script:Engine.SessionId
    & $add 'Rondas' $script:G.Round
    & $add 'Muestras por región y ronda' $script:Engine.Samples
    & $add 'Método' (($script:Cat.Methods.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Value)" }) -join ' · ')
    , $m
}

function Test-CsHasData {
    if (-not ($script:Rows | Where-Object { $_.Count -gt 0 })) { Show-CsMessage 'Todavía no hay mediciones. Pulsa Iniciar primero.' 'Warning'; return $false }
    if ($script:G.Running) { Show-CsMessage 'Espera a que termine la ronda en curso (o pulsa Detener).' 'Warning'; return $false }
    return $true
}

function Invoke-CsExport([string]$Kind) {
    try {
        switch ($Kind) {
            'Excel' {
                if (-not (Test-CsHasData)) { return }
                $f = Export-CsExcel -Rows $script:Rows -Catalog $script:Cat -Meta (Get-CsSessionMeta) -Label $script:G.Label
                Set-CsStatus "Excel guardado: $f"; Invoke-Item $f
            }
            'Csv' {
                if (-not (Test-CsHasData)) { return }
                $f = Export-CsCsv -Rows $script:Rows -Label $script:G.Label
                Set-CsStatus "CSV guardado: $f"; Start-Process explorer.exe "/select,`"$f`""
            }
            'Html' {
                if (-not (Test-CsHasData)) { return }
                $f = Export-CsHtml -Rows $script:Rows -Catalog $script:Cat -Meta (Get-CsSessionMeta)
                Set-CsStatus "Informe guardado: $f"; Invoke-Item $f
            }
            'PowerBI' {
                if ($script:G.Running) { Show-CsMessage 'Espera a que termine la ronda en curso.' 'Warning'; return }
                $hist = Join-Path (Get-CsFolder Datos) 'Mediciones.csv'
                if (-not (Test-Path $hist)) {
                    $cur = [CloudSpeed.Sample[]]@($script:Rows | ForEach-Object { $_.Samples })
                    if ($cur.Count -eq 0) { Show-CsMessage 'Todavía no hay mediciones en el histórico. Mide al menos una vez con "Guardar en el histórico" activado.' 'Warning'; return }
                    Save-CsHistory $cur
                }
                $r = Export-CsPowerBI -Catalog $script:Cat
                Set-CsStatus ("Power BI: {0} mediciones del histórico en {1}" -f $r.Rows, $r.Workbook)
                Start-Process explorer.exe "`"$($r.Folder)`""
                Show-CsMessage ("Datos para Power BI listos ({0} mediciones de todo el histórico).`n`n1. Abre Power BI Desktop (gratuito).`n2. Haz doble clic en Abrir_en_Power_BI.pbids, o usa Obtener datos > Libro de Excel y elige:`n   {1}`n3. Marca las tablas Mediciones, Regiones y Sesiones y pulsa Cargar.`n`nEn Guia-Power-BI.html tienes las medidas DAX y los visuales recomendados. Para actualizar, vuelve a pulsar este botón y luego Actualizar en Power BI." -f $r.Rows, $r.Workbook)
            }
        }
    }
    catch {
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        if ($m -match 'being used|está siendo utilizado|otro proceso') { $m = 'El archivo está abierto en otro programa (Excel o Power BI). Ciérralo y vuelve a intentarlo.' }
        Show-CsMessage "No se pudo exportar:`n$m" 'Error'
    }
}

# ------------------------------------------------------------------ ventana

function Show-CsGui {
    param($Catalog, $Prefs)
    $script:Cat = $Catalog
    $script:G = @{ Round = 0; Running = $false; NextRound = $null; StopRequested = $false; ChartsDirty = $true; LastDraw = [datetime]::MinValue
        RoundSamples = (New-Object 'System.Collections.Generic.List[CloudSpeed.Sample]'); RoundCount = @{}; Label = ''; SessionStart = $null; SessionLogged = $false; Theme = 'System'; Page = 'Latencia'; QuickLeft = 0; PagesDirty = $true }
    $script:PageInit = @{ Latencia = $true }

    # Estilos y paleta como recursos de la aplicación: así las páginas cargadas aparte los encuentran
    if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
    [System.Windows.Application]::Current.ShutdownMode = 'OnExplicitShutdown'
    $theme = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path (Get-CsRoot) 'UI\Theme.xaml') -Raw -Encoding UTF8))
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($theme)
    $script:Ui = @{}
    $win = Import-CsXaml (Join-Path (Get-CsRoot) 'UI\MainWindow.xaml')
    $script:Ui.Window = $win
    $script:Pages = @{}
    $lat = Import-CsXaml (Join-Path (Get-CsRoot) 'UI\Pages\Latencia.xaml')
    $script:Pages['Latencia'] = $lat
    [void]$script:Ui.PageHost.Children.Add($lat)
    $script:Land = Get-CsLand
    $win.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage('es-ES')
    $icon = Join-Path (Get-CsRoot) 'UI\cloudspeed.ico'
    if (Test-Path $icon) { try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icon) } catch { } }
    # En capturas y grabaciones públicas (CS_CAPTURE o CS_DEMO) no se muestra la ruta real (contiene el nombre de usuario)
    $script:Ui.TxtVersion.Text = "v$(Get-CsVersion) · datos: $(if ($env:CS_CAPTURE -or $env:CS_DEMO) { '…\Eureka_CloudSpeed' } else { Get-CsDataRoot })"

    # Filas
    $script:Rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[CloudSpeed.RegionRow]'
    $script:Map = @{}
    foreach ($r in $Catalog.Regions) {
        $row = New-Object CloudSpeed.RegionRow $r, $Catalog.CloudColors[$r.Cloud]
        $row.Selected = $r.HasEndpoint
        $script:Rows.Add($row); $script:Map[$r.Key] = $row
    }
    [CloudSpeed.RowTools]::SortInPlace($script:Rows)
    $script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
    $script:View.Filter = [CloudSpeed.RowTools]::VisibleFilter
    $script:Ui.Grid.ItemsSource = $script:Rows

    # Casillas de nubes y geografías
    $script:CloudBoxes = @(); $script:GeoBoxes = @()
    foreach ($c in $Catalog.Clouds) {
        $n = @($Catalog.Regions | Where-Object { $_.Cloud -eq $c -and $_.HasEndpoint }).Count
        $sp = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal' }
        $dot = New-Object System.Windows.Shapes.Ellipse -Property @{ Width = 9; Height = 9; Fill = (Get-CsBrush $Catalog.CloudColors[$c]); Margin = '0,0,5,0'; VerticalAlignment = 'Center' }
        [void]$sp.Children.Add($dot)
        $tb = New-Object System.Windows.Controls.TextBlock -Property @{ Text = "$c ($n)" }
        [void]$sp.Children.Add($tb)
        $cb = New-Object System.Windows.Controls.CheckBox -Property @{ Content = $sp; Tag = $c; IsChecked = (@($Prefs.Clouds) -contains $c) }
        $cb.Add_Click({ Update-CsFilter })
        [void]$script:Ui.PanelClouds.Children.Add($cb); $script:CloudBoxes += $cb
    }
    foreach ($g in $Catalog.Geos) {
        $on = (@($Prefs.Geos).Count -eq 0) -or (@($Prefs.Geos) -contains $g)
        $cb = New-Object System.Windows.Controls.CheckBox -Property @{ Content = $g; Tag = $g; IsChecked = $on }
        $cb.Add_Click({ Update-CsFilter })
        [void]$script:Ui.PanelGeos.Children.Add($cb); $script:GeoBoxes += $cb
    }

    # Preferencias
    $script:Ui.SldSamples.Value = [math]::Min(20, [math]::Max(1, [int]$Prefs.Samples))
    $script:Ui.TxtSamples.Text = [int]$script:Ui.SldSamples.Value
    $script:Ui.SldInterval.Value = [math]::Min(600, [math]::Max(10, [int]$Prefs.Interval))
    $script:Ui.TxtInterval.Text = "$([int]$script:Ui.SldInterval.Value) s"
    $script:Ui.ChkTls.IsChecked = [bool]$Prefs.Tls
    $script:Ui.ChkContinuous.IsChecked = [bool]$Prefs.Continuous
    $script:Ui.ChkHistory.IsChecked = [bool]$Prefs.SaveHistory
    $script:Ui.ChkAnon.IsChecked = [bool]$Prefs.Anonymize
    $script:G.Retention = $(if ($null -ne $Prefs.RetentionMonths) { [int]$Prefs.RetentionMonths } else { 12 })
    if ($script:Purged) { Set-CsStatus "Conservación de datos: $script:Purged registros con más de $($script:G.Retention) meses borrados del histórico." }
    Set-CsAnonymize ([bool]$Prefs.Anonymize)
    $script:Ui.TxtLabel.Text = [string]$Prefs.Label
    $script:Ui.ColTls.Visibility = $(if ($Prefs.Tls) { 'Visible' } else { 'Collapsed' })

    # Motor
    $script:Engine = New-Object CloudSpeed.ProbeEngine
    $script:Engine.Parallel = 16
    $script:Engine.GapMs = 100

    # Eventos
    $u = $script:Ui
    $u.SldSamples.Add_ValueChanged({ $script:Ui.TxtSamples.Text = [int]$script:Ui.SldSamples.Value })
    $u.SldInterval.Add_ValueChanged({
            $v = [int]$script:Ui.SldInterval.Value
            $script:Ui.TxtInterval.Text = $(if ($v -ge 60) { '{0} min {1}' -f [math]::Floor($v / 60), $(if ($v % 60) { "$($v % 60) s" } else { '' }) } else { "$v s" })
        })
    $u.ChkTls.Add_Click({ $script:Ui.ColTls.Visibility = $(if ($script:Ui.ChkTls.IsChecked) { 'Visible' } else { 'Collapsed' }) })
    $u.TxtSearch.Add_TextChanged({ Update-CsFilter })
    $u.BtnSelAll.Add_Click({ foreach ($r in $script:Rows) { if ($r.Visible -and $r.HasEndpoint) { $r.Selected = $true } }; Update-CsSelectionCount })
    $u.BtnSelNone.Add_Click({ foreach ($r in $script:Rows) { if ($r.Visible) { $r.Selected = $false } }; Update-CsSelectionCount })
    $u.Grid.Add_CurrentCellChanged({ Update-CsSelectionCount })
    $u.Grid.Add_SelectionChanged({ if ($script:Ui.Tabs.SelectedIndex -eq 2) { $script:G.ChartsDirty = $true } })
    $u.BtnStart.Add_Click({ $script:G.StopRequested = $false; [void](Start-CsRound) })
    $u.BtnStop.Add_Click({ Stop-CsMeasure })
    $u.BtnReset.Add_Click({ Reset-CsResults })
    $u.BtnExcel.Add_Click({ Invoke-CsExport 'Excel' })
    $u.BtnPowerBI.Add_Click({ Invoke-CsExport 'PowerBI' })
    $u.BtnCsv.Add_Click({ Invoke-CsExport 'Csv' })
    $u.BtnHtml.Add_Click({ Invoke-CsExport 'Html' })
    $u.BtnFolder.Add_Click({ Start-Process explorer.exe "`"$(Get-CsDataRoot)`"" })
    $u.BtnTheme.Add_Click({ Set-CsTheme (@{ System = 'Light'; Light = 'Dark'; Dark = 'System' }[$script:G.Theme]) })
    $u.Tabs.Add_SelectionChanged({ param($s, $e) if ($e.OriginalSource -eq $script:Ui.Tabs) { $script:G.ChartsDirty = $true; $script:G.LastDraw = [datetime]::MinValue } })
    $u.BtnQuick.Add_Click({ Start-CsQuickTest })
    $u.ChkAnon.Add_Click({ Set-CsAnonymize ([bool]$script:Ui.ChkAnon.IsChecked); Set-CsStatus $(if ($script:Ui.ChkAnon.IsChecked) { "Exportaciones con seudónimo: $(Get-CsMachine)" } else { 'Exportaciones con el nombre real del equipo.' }) })
    $u.BtnConn.Add_Click({ Show-CsConnection })
    foreach ($b in $u.NavPanel.Children) { if ($b -is [System.Windows.Controls.RadioButton]) { $b.Add_Checked({ param($s) Show-CsPage $s.Tag }) } }
    foreach ($h in 'ScrollBars', 'HostLines', 'HostGeo', 'HostMap') { $u[$h].Add_SizeChanged({ $script:G.ChartsDirty = $true }) }

    $win.Add_SourceInitialized({ Set-CsTheme $script:G.Theme })
    $win.Add_Closing({
            $script:Timer.Stop()
            $script:Engine.Cancel()
            Stop-CsPages
            if ($script:Cap) { return }   # las capturas no cambian las preferencias del usuario
            Save-CsPrefs ([pscustomobject]@{
                    Theme = $script:G.Theme; Samples = [int]$script:Ui.SldSamples.Value; Tls = [bool]$script:Ui.ChkTls.IsChecked
                    Continuous = [bool]$script:Ui.ChkContinuous.IsChecked; Interval = [int]$script:Ui.SldInterval.Value; Label = $script:Ui.TxtLabel.Text
                    Clouds = @($script:CloudBoxes | Where-Object IsChecked | ForEach-Object Tag); Geos = @($script:GeoBoxes | Where-Object IsChecked | ForEach-Object Tag)
                    SaveHistory = [bool]$script:Ui.ChkHistory.IsChecked; Anonymize = [bool]$script:Ui.ChkAnon.IsChecked; RetentionMonths = [int]$script:G.Retention
                })
        })

    $script:G.Theme = $(if ($Prefs.Theme) { [string]$Prefs.Theme } else { 'System' })
    Set-CsTheme $script:G.Theme
    Update-CsFilter
    Update-CsCards

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:Timer.Add_Tick({
            try { Invoke-CsTick } catch { Set-CsStatus ("Error: " + $_.Exception.Message) }
            try { Invoke-CsJobsTick } catch { Set-CsStatus ("Error: " + $_.Exception.Message) }
            try { Invoke-CsPagesTick } catch { Set-CsStatus ("Error: " + $_.Exception.Message) }
        })
    $script:Timer.Start()

    if ($env:CS_CAPTURE) { Initialize-CsCapture $env:CS_CAPTURE }
    if ($script:AutoStart) { $win.Add_ContentRendered({ [void](Start-CsRound) }) }
    [void]$win.ShowDialog()
    try { [System.Windows.Application]::Current.Shutdown() } catch { }
}

# ------------------------------------------------------------------ capturas (documentación y pruebas)
# CS_CAPTURE=<carpeta>: mide dos rondas, guarda una captura PNG de cada pestaña (claro y oscuro) y cierra.

function Save-CsCapture([string]$File) {
    $w = $script:Ui.Window.Content
    $w.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]$w.ActualWidth), ([int]$w.ActualHeight), 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($w)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($File); try { $enc.Save($fs) } finally { $fs.Close() }
}

function Initialize-CsCapture([string]$Dir) {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $script:Cap = @{ Dir = $Dir; Step = 0; Wait = 0 }
    $script:Ui.SldSamples.Value = 4
    $script:Ui.ChkContinuous.IsChecked = $true
    $script:Ui.SldInterval.Value = 10
    $script:Ui.ChkHistory.IsChecked = $false
    $script:AutoStart = $true
    $plan = @(
        @{ Page = 'Latencia'; Tab = 0; Theme = 'Light'; Name = '01-latencia-ranking' }, @{ Page = 'Latencia'; Tab = 1; Theme = 'Light'; Name = '02-latencia-grafico' },
        @{ Page = 'Latencia'; Tab = 2; Theme = 'Light'; Name = '03-latencia-evolucion' }, @{ Page = 'Latencia'; Tab = 3; Theme = 'Light'; Name = '04-latencia-mapa' },
        @{ Page = 'Latencia'; Tab = 4; Theme = 'Light'; Name = '05-latencia-azure-vs-aws' }, @{ Page = 'Velocidad'; Theme = 'Light'; Name = '06-velocidad' },
        @{ Page = 'RegionRegion'; Theme = 'Light'; Name = '07-entre-regiones' }, @{ Page = 'Comandos'; Theme = 'Light'; Name = '08-comandos' },
        @{ Page = 'PreciosVm'; Theme = 'Light'; Name = '09-precios-vm'; Click = 'BtnVmLoad'; Wait = 12 }, @{ Page = 'PreciosIa'; Theme = 'Light'; Name = '10-precios-ia'; Click = 'BtnAiLoad'; Wait = 12 },
        @{ Page = 'Regiones'; Theme = 'Light'; Name = '11-regiones' }, @{ Page = 'Mapa'; Theme = 'Light'; Name = '12-mapa'; Lat = $true },
        @{ Page = 'Nubes'; Theme = 'Light'; Name = '13-nubes' }, @{ Page = 'Ip'; Theme = 'Light'; Name = '14-ip'; Query = 'westeurope.api.cognitive.microsoft.com'; Wait = 25 },
        @{ Page = 'Rangos'; Theme = 'Light'; Name = '15-rangos'; Wait = 4 }, @{ Page = 'Ayuda'; Theme = 'Light'; Name = '16-ayuda' },
        @{ Page = 'Estado'; Theme = 'Light'; Name = '00-estado'; Wait = 30 }, @{ Page = 'Estado'; Theme = 'Dark'; Name = '00-estado-oscuro' },
        @{ Page = 'Latencia'; Tab = 0; Theme = 'Dark'; Name = '17-latencia-oscuro' }, @{ Page = 'Mapa'; Theme = 'Dark'; Name = '18-mapa-oscuro' },
        @{ Page = 'PreciosVm'; Theme = 'Dark'; Name = '19-precios-vm-oscuro' })
    $script:Cap.Plan = $plan
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({
            $c = $script:Cap
            if ($script:G.Round -lt 2 -or $script:G.Running) { return }
            if ($script:G.NextRound) { Stop-CsMeasure }
            if ($c.Step -ge $c.Plan.Count) { $this.Stop(); $script:Ui.Window.Close(); return }
            $p = $c.Plan[$c.Step]
            if ($c.Wait -eq 0) {
                if ($script:G.Theme -ne $p.Theme) { Set-CsTheme $p.Theme }
                $script:Ui.("Nav$($p.Page)").IsChecked = $true
                if ($null -ne $p.Tab) { $script:Ui.Tabs.SelectedIndex = $p.Tab }
                if ($p.Lat) { $script:Ui.RbMapLat.IsChecked = $true }
                if ($p.Click -and $script:Ui[$p.Click].IsEnabled) { $script:Ui[$p.Click].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) }
                if ($p.Query) { $script:Ui.TxtIpQuery.Text = $p.Query; Start-CsIpLookup }
                if ($p.Page -eq 'Rangos' -and $script:Ui.GridRng.Items.Count -gt 0) { $script:Ui.GridRng.SelectedIndex = [math]::Min(5, $script:Ui.GridRng.Items.Count - 1) }
                $script:G.ChartsDirty = $true; $script:G.PagesDirty = $true; $script:G.LastDraw = [datetime]::MinValue
                $c.Wait = $(if ($p.Wait) { $p.Wait } else { 1 }); return
            }
            if ($c.Wait -gt 1) { $c.Wait--; if ($script:Jobs.Count -gt 0) { return } }
            if ($p.Page -eq 'Rangos' -and $script:Ui.GridRng.SelectedIndex -lt 0 -and $script:Ui.GridRng.Items.Count -gt 0) { $script:Ui.GridRng.SelectedIndex = [math]::Min(5, $script:Ui.GridRng.Items.Count - 1); return }
            try { Save-CsCapture (Join-Path $c.Dir ($p.Name + '.png')) }
            catch { Add-Content (Join-Path $c.Dir 'errores.txt') ("{0}: {1}" -f $p.Name, $_.Exception.ToString()) }
            $c.Wait = 0; $c.Step++
        })
    $t.Start()
}

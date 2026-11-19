# Info.ps1 - Regiones y zonas, mapa de regiones, y nubes soberanas y entornos.

$script:AwsOptIn = @('af-south-1', 'ap-east-1', 'ap-east-2', 'ap-south-2', 'ap-southeast-3', 'ap-southeast-4', 'ap-southeast-5', 'ap-southeast-6', 'ap-southeast-7',
    'ca-west-1', 'eu-central-2', 'eu-south-1', 'eu-south-2', 'il-central-1', 'me-central-1', 'me-south-1', 'mx-central-1')
$script:CloudLabel = @{ Global = 'Azure'; China = 'Azure China'; USGov = 'Azure US Gov'; Prevista = 'Azure (prevista)'; AWS = 'AWS' }
$script:CloudMapColor = @{ Global = '#2F80ED'; China = '#EF4444'; USGov = '#8B5CF6'; Prevista = '#9CA3AF'; AWS = '#F59E0B' }

function Get-CsRegionDirectory {
    if ($script:RegionDir) { return $script:RegionDir }
    $list = New-Object System.Collections.ArrayList
    foreach ($r in (Get-CsJson 'azure-regions.json').regions) {
        $acc = $(if ($r.cloud -eq 'Prevista') { 'Anunciada' } elseif ($r.restricted) { 'Restringida' } elseif ($r.cloud -eq 'Global') { 'Pública' } else { $script:CloudLabel[$r.cloud] })
        [void]$list.Add([pscustomobject]@{ Cloud = $r.cloud; Key = "Azure|$($r.code)"; Name = $r.name; Code = $r.code; Location = $r.location; Geography = $r.geography; Group = $r.group
                Zones = [int]$r.zones; ZonesText = $(if ($r.zones) { "$($r.zones)" } else { '—' }); Paired = $(if ($r.paired) { $r.paired } else { '—' }); Access = $acc
                Residency = $r.residency; Lat = $r.lat; Lon = $r.lon; Year = $r.year; Link = $r.link; LatencyText = ''; LatencySort = [double]::MaxValue })
    }
    foreach ($r in ($script:Cat.Regions | Where-Object Cloud -eq 'AWS')) {
        [void]$list.Add([pscustomobject]@{ Cloud = 'AWS'; Key = $r.Key; Name = $r.Name; Code = $r.Code; Location = "$($r.City), $($r.Country)"; Geography = $r.Country; Group = $r.Geo
                Zones = 0; ZonesText = '—'; Paired = '—'; Access = $(if ($script:AwsOptIn -contains $r.Code) { 'Opt-in (activar en la cuenta)' } else { 'Pública' })
                Residency = ''; Lat = $r.Lat; Lon = $r.Lon; Year = $null; Link = ''; LatencyText = ''; LatencySort = [double]::MaxValue })
    }
    $script:RegionDir = $list
    return $list
}

function Update-CsRegionLatency {
    foreach ($d in (Get-CsRegionDirectory)) {
        $row = $script:Map[$d.Key]
        if ($row -and $null -ne $row.P50) { $d.LatencyText = '{0:0.0} ms' -f $row.P50; $d.LatencySort = [double]$row.P50 }
        else { $d.LatencyText = ''; $d.LatencySort = [double]::MaxValue }
    }
}

# ------------------------------------------------------------------ regiones y zonas

function Initialize-CsPageRegiones {
    $u = $script:Ui
    [void](Get-CsRegionDirectory)
    $u.CmbRegCloud.Add_SelectionChanged({ Update-CsRegGroups; Update-CsRegList })
    foreach ($c in 'CmbRegGroup', 'CmbRegZones') { $u[$c].Add_SelectionChanged({ Update-CsRegList }) }
    $u.TxtRegSearch.Add_TextChanged({ Update-CsRegList })
    $u.RbRegList.Add_Checked({ Update-CsRegList }); $u.RbRegGeo.Add_Checked({ Update-CsRegList })
    $u.GridReg.Add_MouseDoubleClick({
            $s = $script:Ui.GridReg.SelectedItem
            if ($s) { $script:MapFocus = $s; $script:Ui.NavMapa.IsChecked = $true }
        })
    $u.BtnRegCsv.Add_Click({
            Export-CsObjects ($script:RegShown | Select-Object @{n = 'Nube'; e = { $script:CloudLabel[$_.Cloud] } }, @{n = 'Region'; e = { $_.Name } }, @{n = 'Id'; e = { $_.Code } }, @{n = 'Ubicacion'; e = { $_.Location } },
                    @{n = 'Geografia'; e = { $_.Geography } }, @{n = 'Grupo'; e = { $_.Group } }, @{n = 'Zonas'; e = { $_.Zones } }, @{n = 'Emparejada'; e = { $_.Paired } }, @{n = 'Acceso'; e = { $_.Access } },
                    @{n = 'Residencia'; e = { $_.Residency } }, @{n = 'Latitud'; e = { $_.Lat } }, @{n = 'Longitud'; e = { $_.Lon } }, @{n = 'Latencia'; e = { $_.LatencyText } }) 'Regiones.csv'
        })
    Update-CsRegGroups
}

function Show-CsPageRegiones { Update-CsRegionLatency; if ($script:PageInit.Regiones) { Update-CsRegList } }

function Update-CsRegGroups {
    $u = $script:Ui
    $cloud = [string]$u.CmbRegCloud.SelectedItem.Tag
    $groups = @((Get-CsRegionDirectory) | Where-Object Cloud -eq $cloud | ForEach-Object Group | Where-Object { $_ } | Sort-Object -Unique)
    $u.CmbRegGroup.ItemsSource = @('Todos') + $groups
    $u.CmbRegGroup.SelectedIndex = 0
}

function Update-CsRegList {
    $u = $script:Ui
    $cloud = [string]$u.CmbRegCloud.SelectedItem.Tag
    $grp = [string]$u.CmbRegGroup.SelectedItem
    $z = $u.CmbRegZones.SelectedIndex
    $q = $u.TxtRegSearch.Text.Trim()
    $rows = @((Get-CsRegionDirectory) | Where-Object {
            $_.Cloud -eq $cloud -and ($grp -eq 'Todos' -or -not $grp -or $_.Group -eq $grp) -and
            ($z -eq 0 -or ($z -eq 1 -and $_.Zones -gt 0) -or ($z -eq 2 -and $_.Zones -eq 0)) -and
            (-not $q -or "$($_.Name) $($_.Code) $($_.Location) $($_.Geography) $($_.Group)" -like "*$q*")
        } | Sort-Object Name)
    $script:RegShown = $rows
    $geo = [bool]$u.RbRegGeo.IsChecked
    $u.GridReg.Visibility = $(if ($geo) { 'Collapsed' } else { 'Visible' })
    $u.GridGeo.Visibility = $(if ($geo) { 'Visible' } else { 'Collapsed' })
    if ($geo) {
        $u.GridGeo.ItemsSource = @($rows | Group-Object Geography | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ Geography = $_.Name; Count = $_.Count; WithZones = @($_.Group | Where-Object Zones -gt 0).Count
                    Regions = ($_.Group | ForEach-Object { $_.Name + $(if ($_.Zones) { ' (AZ)' } else { '' }) }) -join ' · ' }
            })
    }
    else { $u.GridReg.ItemsSource = $rows }
    $zones = @($rows | Where-Object Zones -gt 0).Count
    $u.TxtRegInfo.Text = "$($rows.Count) regiones · $zones con zonas de disponibilidad · $(@($rows | Group-Object Geography).Count) geografías" +
    $(if ($cloud -eq 'AWS') { ' · AWS: las regiones opt-in hay que activarlas en la cuenta antes de usarlas.' } elseif ($cloud -eq 'Prevista') { ' · Regiones anunciadas, todavía no disponibles.' } else { '' })
}

# ------------------------------------------------------------------ mapa

function Initialize-CsPageMapa {
    $u = $script:Ui
    [void](Get-CsRegionDirectory)
    foreach ($c in 'ChkMapAzure', 'ChkMapAws', 'ChkMapSov', 'ChkMapPlanned', 'ChkMapLabels') { $u[$c].Add_Click({ $script:G.PagesDirty = $true }) }
    $u.RbMapCloud.Add_Checked({ $script:G.PagesDirty = $true }); $u.RbMapLat.Add_Checked({ $script:G.PagesDirty = $true })
    $u.CmbMapZoom.Add_SelectionChanged({ $script:G.PagesDirty = $true })
    $u.TxtMapSearch.Add_TextChanged({ $script:G.PagesDirty = $true })
    $u.HostWorld.Add_SizeChanged({ $script:G.PagesDirty = $true })
    $u.BtnMapMeasure.Add_Click({ Start-CsMapMeasure })
    $script:MapClick = [Action[object]] { param($d) Select-CsMapRegion $d }
    $u.TxtMapLegend.Text = "Por nube: azul Azure · ámbar AWS · rojo Azure China · morado Azure US Gov · gris (hueco) prevista.`nPor latencia: verde < 50 ms · lima < 100 · ámbar < 175 · rojo ≥ 175 · hueco sin medir."
}

function Show-CsPageMapa {
    Update-CsRegionLatency
    if ($script:MapFocus) {
        $f = $script:MapFocus; $script:MapFocus = $null
        if ($f.Cloud -in 'China', 'USGov') { $script:Ui.ChkMapSov.IsChecked = $true }
        if ($f.Cloud -eq 'Prevista') { $script:Ui.ChkMapPlanned.IsChecked = $true }
        $script:Ui.TxtMapSearch.Text = $f.Name
        Select-CsMapRegion $f
    }
    $script:G.PagesDirty = $true
}

function Update-CsPageMapa {
    if (-not $script:G.PagesDirty) { return }
    $script:G.PagesDirty = $false
    $u = $script:Ui
    $byLat = [bool]$u.RbMapLat.IsChecked
    $q = $u.TxtMapSearch.Text.Trim()
    $pts = New-Object 'System.Collections.Generic.List[CloudSpeed.MapPoint]'
    foreach ($d in (Get-CsRegionDirectory)) {
        $show = switch ($d.Cloud) { 'Global' { $u.ChkMapAzure.IsChecked } 'AWS' { $u.ChkMapAws.IsChecked } 'Prevista' { $u.ChkMapPlanned.IsChecked } default { $u.ChkMapSov.IsChecked } }
        if (-not $show -or $null -eq $d.Lat) { continue }
        $p = New-Object CloudSpeed.MapPoint
        $p.Lon = $d.Lon; $p.Lat = $d.Lat; $p.Tag = $d; $p.Label = $d.Name
        $match = $q -and ("$($d.Name) $($d.Code) $($d.Location)" -like "*$q*")
        if ($byLat) {
            if ($d.LatencySort -lt [double]::MaxValue) { $p.Color = [CloudSpeed.Stats]::Level($d.LatencySort); $p.Size = 11 }
            else { $p.Color = $script:CloudMapColor[$d.Cloud]; $p.Hollow = $true; $p.Size = 7 }
        }
        else { $p.Color = $script:CloudMapColor[$d.Cloud]; $p.Size = 9; $p.Hollow = $d.Cloud -eq 'Prevista' }
        if ($match) { $p.Size = 15 }
        if ($q -and -not $match) { $p.Label = '' }
        $p.Tip = "$($script:CloudLabel[$d.Cloud]) · $($d.Name)`n$($d.Location)" + $(if ($d.LatencyText) { "`nLatencia: $($d.LatencyText)" } else { '' })
        $pts.Add($p)
    }
    $b = [double[]](([string]$u.CmbMapZoom.SelectedItem.Tag) -split ',')
    $labels = [bool]$u.ChkMapLabels.IsChecked -or [bool]$q
    [CloudSpeed.Charts]::Map($u.CanvasWorld, $script:Land, $pts, $script:G.ChartTheme, $u.HostWorld.ActualWidth, $u.HostWorld.ActualHeight, $b[0], $b[1], $b[2], $b[3], $labels, $script:MapClick)
}

function Select-CsMapRegion($d) {
    $u = $script:Ui
    $script:MapSel = $d
    $u.TxtMapName.Text = "$($d.Name)"
    $lines = @("Nube: $($script:CloudLabel[$d.Cloud])", "Id: $($d.Code)", "Ubicación: $($d.Location)", "Geografía: $($d.Geography)")
    if ($d.Cloud -ne 'AWS') { $lines += "Zonas de disponibilidad: $($d.ZonesText)", "Región emparejada: $($d.Paired)" }
    $lines += "Acceso: $($d.Access)"
    if ($d.Residency) { $lines += "Residencia de datos: $($d.Residency)" }
    if ($d.Year) { $lines += "Abierta en: $($d.Year)" }
    if ($d.LatencyText) { $lines += "Latencia medida (P50): $($d.LatencyText)" }
    $u.TxtMapDetails.Text = $lines -join "`n"
    $info = $script:Cat.Regions | Where-Object Key -eq $d.Key | Select-Object -First 1
    $u.BtnMapMeasure.IsEnabled = [bool]($info -and $info.HasEndpoint)
    $script:MapSelInfo = $info
}

function Start-CsMapMeasure {
    $r = $script:MapSelInfo
    if (-not $r) { return }
    $script:Ui.BtnMapMeasure.IsEnabled = $false
    [void](Start-CsJob -Status "Midiendo $($r.Label)…" -Arguments @($r) -Script {
            param($r)
            $e = New-Object CloudSpeed.ProbeEngine; $e.Samples = 10; $e.GapMs = 60
            [CloudSpeed.Runner]::RunBlocking($e, [CloudSpeed.RegionInfo[]]@($r), 1, $null)
        } -OnDone {
            param($res, $err)
            $script:Ui.BtnMapMeasure.IsEnabled = $true
            if ($err) { Set-CsStatus "Error: $err"; return }
            # Las muestras se añaden al ranking de latencia como una ronda más
            $script:G.Round++
            foreach ($s in @($res)) { $s.Round = $script:G.Round; $script:Map[$s.Region.Key].Add($s) }
            $row = $script:Map[$script:MapSelInfo.Key]; $row.Recompute()
            [CloudSpeed.RowTools]::SortInPlace($script:Rows); Update-CsCards
            Update-CsRegionLatency
            Select-CsMapRegion $script:MapSel
            $script:G.PagesDirty = $true
            Set-CsStatus ("{0}: {1:0.0} ms (P50 de {2} muestras)" -f $row.Label, $row.P50, $row.Count)
        })
}

# ------------------------------------------------------------------ nubes soberanas y entornos

function Initialize-CsPageNubes {
    $u = $script:Ui
    $env = Get-CsJson 'azure-environments.json'
    $dir = Get-CsRegionDirectory
    $count = @{ AzureCloud = @($dir | Where-Object Cloud -eq 'Global').Count; AzureUSGovernment = @($dir | Where-Object Cloud -eq 'USGov').Count; AzureChinaCloud = @($dir | Where-Object Cloud -eq 'China').Count }
    foreach ($c in $env.clouds) {
        $b = New-Object System.Windows.Controls.Border
        $b.Style = $u.Window.FindResource('Card')
        $b.Margin = '0,0,10,0'
        $sp = New-Object System.Windows.Controls.StackPanel
        $t = New-Object System.Windows.Controls.TextBlock -Property @{ Text = $c.name; FontSize = 16; FontWeight = 'SemiBold' }
        $s = New-Object System.Windows.Controls.TextBlock -Property @{ Text = "$($c.id) · $($c.nick) · $($count[$c.id]) regiones"; Style = $u.Window.FindResource('Muted') }
        $d = New-Object System.Windows.Controls.TextBlock -Property @{ Text = $c.description; TextWrapping = 'Wrap'; Margin = '0,8,0,4' }
        $m = New-Object System.Windows.Controls.TextBlock -Property @{ Text = "Para: $($c.market)`nOpera: $($c.operator)"; TextWrapping = 'Wrap'; Style = $u.Window.FindResource('Muted') }
        $btn = New-Object System.Windows.Controls.Button -Property @{ Content = "Abrir $($c.portal -replace 'https://', '')"; HorizontalAlignment = 'Left'; Margin = '0,8,0,0'; Tag = $c.portal }
        # Solo se abren direcciones https (el catálogo es un archivo editable: nunca se lanza otra cosa)
        $btn.Add_Click({ param($x) if ([string]$x.Tag -match '^https://[\w.-]+(/[\w./?=&%-]*)?$') { Start-Process ([string]$x.Tag) } })
        foreach ($e in $t, $s, $d, $m, $btn) { [void]$sp.Children.Add($e) }
        $b.Child = $sp
        [void]$u.PanelClouds.Children.Add($b)
    }
    $script:EnvRows = @($env.properties | ForEach-Object { [pscustomobject]@{ Property = $_[0]; Global = $_[1]; USGov = $_[2]; China = $_[3] } })
    $u.GridEnv.ItemsSource = $script:EnvRows
    $u.TxtEnvSearch.Add_TextChanged({
            $q = $script:Ui.TxtEnvSearch.Text.Trim()
            $script:Ui.GridEnv.ItemsSource = @($script:EnvRows | Where-Object { -not $q -or "$($_.Property) $($_.Global) $($_.USGov) $($_.China)" -like "*$q*" })
        })
    $u.BtnEnvCsv.Add_Click({ Export-CsObjects ($script:Ui.GridEnv.ItemsSource | Select-Object @{n = 'Propiedad'; e = { $_.Property } }, @{n = 'AzureCloud'; e = { $_.Global } }, @{n = 'AzureUSGovernment'; e = { $_.USGov } }, @{n = 'AzureChinaCloud'; e = { $_.China } }) 'Entornos_Azure.csv' })
    # Si está Az.Accounts, se leen los valores exactos de la versión instalada
    if (Get-Module -ListAvailable Az.Accounts -ErrorAction SilentlyContinue) {
        [void](Start-CsJob -Script {
                Import-Module Az.Accounts -ErrorAction Stop
                $e = @{}; foreach ($n in 'AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud') { $e[$n] = Get-AzEnvironment -Name $n }
                $props = $e.AzureCloud.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Name -notin 'Name', 'Type' } | ForEach-Object Name
                foreach ($p in $props) { [pscustomobject]@{ Property = $p; Global = $e.AzureCloud.$p; USGov = $e.AzureUSGovernment.$p; China = $e.AzureChinaCloud.$p } }
            } -OnDone {
                param($res, $err)
                if ($err -or -not $res) { return }
                $script:EnvRows = @($res | ForEach-Object { foreach ($k in 'Global', 'USGov', 'China') { if (-not $_.$k) { $_.$k = '—' } }; $_ })
                $script:Ui.GridEnv.ItemsSource = $script:EnvRows
                Set-CsStatus 'Entornos leídos de Az.Accounts (Get-AzEnvironment).'
            })
    }
}

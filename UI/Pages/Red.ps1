# Red.ps1 - Búsqueda de IP y rangos de IP de Azure (Service Tags) y AWS (ip-ranges.json).

$script:IpSources = @(
    @{ Cloud = 'Azure Public'; File = 'azure-public.json'; Page = 'https://www.microsoft.com/en-us/download/details.aspx?id=56519'; Pattern = 'ServiceTags_Public_\d+\.json' }
    @{ Cloud = 'Azure China'; File = 'azure-china.json'; Page = 'https://www.microsoft.com/en-us/download/details.aspx?id=57062'; Pattern = 'ServiceTags_China_\d+\.json' }
    @{ Cloud = 'Azure US Gov'; File = 'azure-usgov.json'; Page = 'https://www.microsoft.com/en-us/download/details.aspx?id=57063'; Pattern = 'ServiceTags_AzureGovernment_\d+\.json' }
    @{ Cloud = 'AWS'; File = 'aws.json'; Url = 'https://ip-ranges.amazonaws.com/ip-ranges.json' }
)

function Get-CsIpFolder {
    $d = Join-Path (Get-CsCacheFolder) 'rangos-ip'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Get-CsIpDataStatus {
    $dir = Get-CsIpFolder
    $parts = foreach ($s in $script:IpSources) {
        $f = Join-Path $dir $s.File
        if (Test-Path $f) { '{0}: {1:dd/MM/yyyy}' -f $s.Cloud, (Get-Item $f).LastWriteTime } else { "$($s.Cloud): sin descargar" }
    }
    $loaded = $(if ($script:IpData) { " · $(@($script:IpData).Count) etiquetas cargadas" } else { '' })
    'Datos de rangos · ' + ($parts -join ' · ') + $loaded
}

function Initialize-CsPageIp {
    $u = $script:Ui
    $u.BtnIpLookup.Add_Click({ Start-CsIpLookup })
    $u.TxtIpQuery.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-CsIpLookup } })
    foreach ($b in 'BtnIpEx1', 'BtnIpEx2', 'BtnIpEx3', 'BtnIpEx4') { $u[$b].Add_Click({ param($s) $script:Ui.TxtIpQuery.Text = [string]$s.Content; Start-CsIpLookup }) }
    $u.BtnIpUpdate.Add_Click({ Update-CsIpData -Force })
    Show-CsIpStatus
    Import-CsIpData
}

function Show-CsIpStatus { foreach ($n in 'TxtIpData') { if ($script:Ui[$n]) { $script:Ui[$n].Text = Get-CsIpDataStatus } } }

function Update-CsIpData([switch]$Force) {
    <# Descarga (si faltan o con -Force) los cuatro archivos de rangos y después los carga. #>
    $dir = Get-CsIpFolder
    $need = @($script:IpSources | Where-Object { $Force -or -not (Test-Path (Join-Path $dir $_.File)) })
    if ($need.Count -eq 0) { Import-CsIpData; return }
    if ($script:Ui.BtnIpUpdate) { $script:Ui.BtnIpUpdate.IsEnabled = $false }
    [void](Start-CsJob -Status 'Descargando rangos de IP de Microsoft y AWS…' -Arguments @($need, $dir) -Script {
            param($need, $dir)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $errs = @()
            foreach ($s in $need) {
                try {
                    $url = $s.Url
                    if (-not $url) {
                        $page = Invoke-WebRequest -Uri $s.Page -UseBasicParsing -TimeoutSec 60
                        $m = [regex]::Match($page.Content, 'https://download\.microsoft\.com/[^"''\s]+' + $s.Pattern)
                        if (-not $m.Success) { throw 'no se encontró el enlace de descarga en la página de Microsoft' }
                        $url = $m.Value
                    }
                    $tmp = Join-Path $dir ($s.File + '.tmp')
                    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
                    Move-Item $tmp (Join-Path $dir $s.File) -Force
                }
                catch { $errs += "$($s.Cloud): $($_.Exception.Message)" }
            }
            $errs
        } -OnDone {
            param($res, $err)
            if ($script:Ui.BtnIpUpdate) { $script:Ui.BtnIpUpdate.IsEnabled = $true }
            $e = @($res | Where-Object { $_ }) + @($err | Where-Object { $_ })
            if ($e.Count) { Show-CsMessage ("Algunos rangos no se pudieron descargar:`n" + ($e -join "`n")) 'Warning' }
            $script:IpData = $null
            Import-CsIpData
        })
}

function Import-CsIpData {
    if ($script:IpData -or $script:IpLoading) { Show-CsIpStatus; return }
    $dir = Get-CsIpFolder
    $present = @($script:IpSources | Where-Object { Test-Path (Join-Path $dir $_.File) })
    if ($present.Count -eq 0) { Show-CsIpStatus; return }
    $script:IpLoading = $true
    [void](Start-CsJob -Status 'Cargando rangos de IP…' -Arguments @($present, $dir) -Script {
            param($present, $dir)
            $all = New-Object 'System.Collections.Generic.List[CloudSpeed.IpRangeEntry]'
            foreach ($s in $present) {
                $json = [IO.File]::ReadAllText((Join-Path $dir $s.File))
                if ($s.Cloud -eq 'AWS') { $e = [CloudSpeed.IpRanges]::LoadAws($json) } else { $e = [CloudSpeed.IpRanges]::LoadAzure($json, $s.Cloud) }
                foreach ($x in $e) { $all.Add($x) }
            }
            , $all
        } -OnDone {
            param($res, $err)
            $script:IpLoading = $false
            $script:IpData = @($res | ForEach-Object { $_ })
            if ($script:IpData.Count -eq 0) {
                $script:IpData = $null
                Show-CsIpStatus
                Show-CsMessage "No se pudieron cargar los rangos de IP:`n$err" 'Warning'
                return
            }
            Show-CsIpStatus
            if ($script:PageInit.Rangos) { Update-CsRngLists }
            if ($script:IpPending) { $script:IpPending = $false; Start-CsIpLookup }
            Set-CsStatus "Rangos de IP cargados: $(@($script:IpData).Count) etiquetas."
        })
}

function Start-CsIpLookup {
    $u = $script:Ui
    $q = $u.TxtIpQuery.Text.Trim()
    if (-not $q) { return }
    if (-not $script:IpData) {
        $script:IpPending = $true
        if ($script:IpLoading) { $u.TxtIpInfo.Text = 'Cargando rangos…'; return }
        $u.TxtIpInfo.Text = 'Descargando los rangos de IP por primera vez…'
        Update-CsIpData; return
    }
    $clouds = @()
    if ($u.ChkIpPublic.IsChecked) { $clouds += 'Azure Public' }
    if ($u.ChkIpChina.IsChecked) { $clouds += 'Azure China' }
    if ($u.ChkIpGov.IsChecked) { $clouds += 'Azure US Gov' }
    if ($u.ChkIpAws.IsChecked) { $clouds += 'AWS' }
    $entries = [CloudSpeed.IpRangeEntry[]]@($script:IpData | Where-Object { $clouds -contains $_.Cloud })
    $u.BtnIpLookup.IsEnabled = $false
    $u.TxtIpInfo.Text = 'Buscando…'
    [void](Start-CsJob -Arguments @($q, $entries) -Script {
            param($q, $entries)
            $h = $q
            if ($h -match '^[a-z]+://') { $h = ([uri]$h).Host }
            $h = $h.Trim().TrimEnd('/').Trim('[', ']')
            $ip = $null
            $ips = $(if ([Net.IPAddress]::TryParse($h, [ref]$ip)) { @($ip) } else { [Net.Dns]::GetHostAddresses($h) })
            $out = @()
            foreach ($a in $ips) {
                $m = [CloudSpeed.IpRanges]::Lookup($entries, $a)
                if ($m.Count -eq 0) { $out += [pscustomobject]@{ Ip = $a.ToString(); Cloud = '—'; Name = 'Sin coincidencias en los rangos seleccionados'; Service = ''; Region = ''; Prefix = '' } }
                else { $out += $m }
            }
            [pscustomobject]@{ Host = $h; Ips = @($ips | ForEach-Object { $_.ToString() }); Matches = $out }
        } -OnDone {
            param($res, $err)
            $u = $script:Ui
            $u.BtnIpLookup.IsEnabled = $true
            if ($err -or -not $res) { $u.TxtIpInfo.Text = "No se pudo resolver: $err"; $u.GridIp.ItemsSource = $null; return }
            $r = @($res)[0]
            $u.GridIp.ItemsSource = @($r.Matches)
            $hit = @($r.Matches | Where-Object { $_.Cloud -ne '—' })
            $best = $hit | Select-Object -First 1
            $u.TxtIpInfo.Text = "$($r.Host) → $($r.Ips -join ', ')    " + $(if ($best) { "· $($best.Cloud) · $($best.Name)$(if ($best.Region) { ' · región ' + $best.Region }) · $($hit.Count) coincidencias" } else { '· no pertenece a los rangos publicados seleccionados' })
        })
}

# ------------------------------------------------------------------ rangos

function Initialize-CsPageRangos {
    $u = $script:Ui
    $u.CmbRngCloud.Add_SelectionChanged({ Update-CsRngLists })
    foreach ($c in 'CmbRngService', 'CmbRngRegion') { $u[$c].Add_SelectionChanged({ Update-CsRngGrid }) }
    $u.TxtRngSearch.Add_TextChanged({ Update-CsRngGrid })
    $u.GridRng.Add_SelectionChanged({ Update-CsRngPrefixes })
    $u.ChkRngV4.Add_Click({ Update-CsRngPrefixes }); $u.ChkRngV6.Add_Click({ Update-CsRngPrefixes })
    $u.BtnRngCopy.Add_Click({ Copy-CsText $script:Ui.TxtRngPrefixes.Text 'Prefijos' })
    $u.BtnRngSave.Add_Click({
            $sel = $script:Ui.GridRng.SelectedItem
            if (-not $sel) { return }
            $f = Save-CsFileDialog ("{0}.txt" -f ($sel.Name -replace '[^\w\.-]', '_')) 'Texto (*.txt)|*.txt'
            if ($f) { [IO.File]::WriteAllText($f, $script:Ui.TxtRngPrefixes.Text); Set-CsStatus "Guardado: $f" }
        })
    if ($script:IpData) { Update-CsRngLists } else { $u.TxtRngInfo.Text = 'Preparando los datos de rangos…'; Update-CsIpData }
}

function Update-CsRngLists {
    $u = $script:Ui
    if (-not $script:IpData) { return }
    $cloud = [string]$u.CmbRngCloud.SelectedItem.Tag
    $e = @($script:IpData | Where-Object Cloud -eq $cloud)
    $u.CmbRngService.ItemsSource = @('Todos') + @($e | ForEach-Object Service | Where-Object { $_ } | Sort-Object -Unique)
    $u.CmbRngRegion.ItemsSource = @('Todas', '(global, sin región)') + @($e | ForEach-Object Region | Where-Object { $_ } | Sort-Object -Unique)
    $u.CmbRngService.SelectedIndex = 0; $u.CmbRngRegion.SelectedIndex = 0
    Update-CsRngGrid
}

function Update-CsRngGrid {
    $u = $script:Ui
    if (-not $script:IpData) { return }
    $cloud = [string]$u.CmbRngCloud.SelectedItem.Tag
    $svc = [string]$u.CmbRngService.SelectedItem; $reg = [string]$u.CmbRngRegion.SelectedItem
    $q = $u.TxtRngSearch.Text.Trim()
    $rows = @($script:IpData | Where-Object {
            $_.Cloud -eq $cloud -and ($svc -eq 'Todos' -or -not $svc -or $_.Service -eq $svc) -and
            ($reg -eq 'Todas' -or -not $reg -or ($reg -eq '(global, sin región)' -and -not $_.Region) -or $_.Region -eq $reg) -and
            (-not $q -or $_.Name -like "*$q*")
        })
    $u.GridRng.ItemsSource = $rows
    $u.TxtRngInfo.Text = "$($rows.Count) etiquetas · " + (Get-CsIpDataStatus)
}

function Update-CsRngPrefixes {
    $u = $script:Ui
    $sel = $u.GridRng.SelectedItem
    if (-not $sel) { $u.TxtRngPrefixes.Text = ''; $u.TxtRngSel.Text = 'Prefijos'; return }
    $txt = $sel.Text([bool]$u.ChkRngV4.IsChecked, [bool]$u.ChkRngV6.IsChecked)
    $u.TxtRngPrefixes.Text = $txt
    $u.TxtRngSel.Text = "$($sel.Name) · $(@($txt -split "`n" | Where-Object { $_ }).Count) prefijos"
}

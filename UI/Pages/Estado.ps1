# Estado.ps1 - Estado de servicios: páginas de estado oficiales + comprobación propia desde la red.

# Consulta de las páginas de estado oficiales (en segundo plano). Devuelve CloudSpeed.StatusRow.
$script:StatusOfficialJob = {
    param($Sources)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $now = Get-Date
    function New-Row($s, [int]$lvl, [string]$state, [string]$detail, [string]$updated, [string]$service) {
        $r = New-Object CloudSpeed.StatusRow
        $r.Source = 'Oficial'; $r.Provider = $s.provider; $r.Service = $(if ($service) { $service } else { $s.service })
        $r.Level = $lvl; $r.State = $state; $r.Detail = $detail; $r.Updated = $updated; $r.Page = $s.page; $r.Time = $now
        $r
    }
    function Get-Plain([string]$h) {
        if (-not $h) { return '' }
        $t = [regex]::Replace($h, '<[^>]+>', ' ')
        $t = [System.Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' '
        $t = $t.Trim()
        if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '…' }
        $t
    }
    function Get-MsLevel([string]$st) {
        switch -Regex ($st) {
            '^(Available|Operational|ServiceOperational|ServiceRestored|)$' { 0; break }
            'Interruption|Outage|Incident|Unavailable|Down' { 3; break }
            'Degrad|Investigat|Advisory|Restoring|Mitigat|Extended' { 2; break }
            default { 1 }
        }
    }
    foreach ($s in $Sources) {
        try {
            $resp = Invoke-WebRequest -Uri $s.url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Eureka_CloudSpeed/1.0' }
            switch ($s.type) {
                'mspost' {
                    $j = $resp.Content | ConvertFrom-Json
                    $lvl = Get-MsLevel ([string]$j.Status)
                    $detail = $(if ($lvl -gt 0) { (@((Get-Plain $j.Title), (Get-Plain $j.Message)) | Where-Object { $_ }) -join ' · ' } else { 'Sin incidencias publicadas.' })
                    New-Row $s $lvl $(if ($lvl -eq 0) { 'Operativo' } else { [CloudSpeed.StatusRow]::LevelName($lvl) }) $detail ([datetime]$j.LastUpdatedTime).ToLocalTime().ToString('dd/MM HH:mm') ''
                }
                'mslist' {
                    $j = $resp.Content | ConvertFrom-Json; $items = @($j)   # PS 5.1: la lista JSON llega como un solo objeto
                    $bad = @($items | Where-Object { (Get-MsLevel ([string]$_.Status)) -gt 0 })
                    if ($bad.Count -eq 0) { New-Row $s 0 'Operativo' ("{0} productos operativos." -f $items.Count) $(if ($items) { ([datetime]$items[0].LastUpdatedTime).ToLocalTime().ToString('dd/MM HH:mm') }) '' }
                    foreach ($b in $bad) { $l = Get-MsLevel ([string]$b.Status); New-Row $s $l ([CloudSpeed.StatusRow]::LevelName($l)) ((@((Get-Plain $b.Title), (Get-Plain $b.Message)) | Where-Object { $_ }) -join ' · ') ([datetime]$b.LastUpdatedTime).ToLocalTime().ToString('dd/MM HH:mm') "$($s.service): $($b.ServiceDisplayName)" }
                }
                'rss' {
                    [xml]$x = $resp.Content
                    $items = @($x.SelectNodes('//item'))
                    if ($items.Count -eq 0) { New-Row $s 0 'Operativo' 'Sin incidencias publicadas en el RSS.' (Get-Date).ToString('dd/MM HH:mm') '' }
                    foreach ($i in ($items | Select-Object -First 10)) {
                        $d = $(try { ([datetime]$i.pubDate).ToString('dd/MM HH:mm') } catch { '' })
                        New-Row $s 2 'Incidencia' ("{0} · {1}" -f (Get-Plain $i.title), (Get-Plain $i.description)) $d "$($s.service)"
                    }
                }
                'devops' {
                    $j = $resp.Content | ConvertFrom-Json
                    $map = @{ healthy = 0; advisory = 1; degraded = 2; unhealthy = 3 }
                    $lvl = $(if ($map.ContainsKey([string]$j.status.health)) { $map[[string]$j.status.health] } else { 1 })
                    $bad = foreach ($sv in $j.services) { foreach ($g in $sv.geographies) { if ($g.health -ne 'healthy') { "$($sv.id) ($($g.name)): $($g.health)" } } }
                    New-Row $s $lvl $(if ($lvl -eq 0) { 'Operativo' } else { [CloudSpeed.StatusRow]::LevelName($lvl) }) ((@([string]$j.status.message) + @($bad)) -join ' · ') ([datetime]$j.lastUpdated).ToLocalTime().ToString('dd/MM HH:mm') ''
                }
                'aws' {
                    $b = $resp.RawContentStream.ToArray()
                    $txt = $(if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { [Text.Encoding]::BigEndianUnicode.GetString($b) } elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { [Text.Encoding]::Unicode.GetString($b) } else { [Text.Encoding]::UTF8.GetString($b) })
                    $j = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
                    $ev = @(@($j) | Where-Object { $_ -and [int]$_.status -gt 0 })
                    if ($ev.Count -eq 0) { New-Row $s 0 'Operativo' 'Sin eventos activos.' (Get-Date).ToString('dd/MM HH:mm') '' }
                    foreach ($e in $ev) {
                        $l = [math]::Min(3, [int]$e.status)
                        $when = $(try { [DateTimeOffset]::FromUnixTimeSeconds([long]$e.date).LocalDateTime.ToString('dd/MM HH:mm') } catch { '' })
                        New-Row $s $l ([CloudSpeed.StatusRow]::LevelName($l)) ("{0} · región {1}" -f (Get-Plain $e.summary), $e.region_name) $when "AWS: $($e.service_name) ($($e.region_name))"
                    }
                }
                'google' {
                    $j = $resp.Content | ConvertFrom-Json
                    $act = @(@($j) | Where-Object { $_ -and -not $_.end })
                    if ($act.Count -eq 0) { New-Row $s 0 'Operativo' 'Sin incidencias activas.' (Get-Date).ToString('dd/MM HH:mm') '' }
                    foreach ($a in $act) {
                        $l = switch ([string]$a.severity) { 'high' { 3 } 'medium' { 2 } default { 1 } }
                        $prods = @($a.affected_products | ForEach-Object { $_.title }) -join ', '
                        New-Row $s $l ([CloudSpeed.StatusRow]::LevelName($l)) ("{0}{1}" -f (Get-Plain $a.external_desc), $(if ($prods) { " · $prods" })) ([datetime]$a.modified).ToLocalTime().ToString('dd/MM HH:mm') ''
                    }
                }
                'statuspage' {
                    $j = $resp.Content | ConvertFrom-Json
                    $l = switch ([string]$j.status.indicator) { 'none' { 0 } 'maintenance' { 1 } 'minor' { 2 } default { 3 } }
                    $inc = @($j.incidents | Select-Object -First 3 | ForEach-Object { $_.name }) -join ' · '
                    New-Row $s $l $(if ($l -eq 0) { 'Operativo' } else { [CloudSpeed.StatusRow]::LevelName($l) }) ((@([string]$j.status.description, $inc) | Where-Object { $_ }) -join ' · ') ([datetime]$j.page.updated_at).ToLocalTime().ToString('dd/MM HH:mm') ''
                }
            }
        }
        catch {
            New-Row $s -1 'Sin datos' ("La página de estado no responde: " + $_.Exception.Message) (Get-Date).ToString('dd/MM HH:mm') ''
        }
    }
}

$script:StatusProbeJob = {
    param($Targets)
    [CloudSpeed.StatusProbe]::Run($Targets, 6000)
}

function Initialize-CsPageEstado {
    $u = $script:Ui
    $cfg = Get-CsJson 'status-sources.json'
    $targets = New-Object 'System.Collections.Generic.List[CloudSpeed.ProbeTarget]'
    foreach ($p in $cfg.probes) { $t = New-Object CloudSpeed.ProbeTarget; $t.Provider = $p.provider; $t.Service = $p.service; $t.Url = $p.url; $targets.Add($t) }
    $script:St = @{ Sources = @($cfg.official); Targets = $targets; Official = @(); Probes = @(); Pending = 0; Next = $null; Last = $null }
    $u.BtnStRefresh.Add_Click({ Start-CsStatusCheck })
    $u.ChkStAuto.Add_Click({ Set-CsStatusNext })
    $u.CmbStEvery.Add_SelectionChanged({ Set-CsStatusNext })
    $u.GridStOfficial.Add_SelectionChanged({ $script:Ui.BtnStOpen.IsEnabled = $null -ne $script:Ui.GridStOfficial.SelectedItem })
    $u.BtnStOpen.Add_Click({
            $p = [string]$script:Ui.GridStOfficial.SelectedItem.Page
            if ($p -match '^https://[\w.-]+(/[\w./?=&%#-]*)?$') { Start-Process $p }
        })
    $u.BtnStCsv.Add_Click({
            $all = @($script:St.Official) + @($script:St.Probes)
            Export-CsObjects ($all | Select-Object @{n = 'Fecha'; e = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, @{n = 'Fuente'; e = { $_.Source } }, @{n = 'Proveedor'; e = { $_.Provider } },
                    @{n = 'Servicio'; e = { $_.Service } }, @{n = 'Estado'; e = { $_.State } }, @{n = 'Detalle'; e = { $_.Detail } }, @{n = 'DNS_ms'; e = { $_.DnsMs } }, @{n = 'Conexion_ms'; e = { $_.ConnectMs } },
                    @{n = 'HTTPS_ms'; e = { $_.HttpMs } }, @{n = 'Codigo'; e = { $_.Code } }) ('Estado_servicios_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date))
        })
    Start-CsStatusCheck
}

function Set-CsStatusNext {
    $u = $script:Ui
    if ($u.ChkStAuto.IsChecked) {
        $script:St.Next = (Get-Date).AddSeconds([int]$u.CmbStEvery.SelectedItem.Tag)
        $u.TxtStNext.Text = 'Próxima comprobación: {0:HH:mm:ss} (también fuera de esta sección)' -f $script:St.Next
    }
    else { $script:St.Next = $null; $u.TxtStNext.Text = '' }
}

function Start-CsStatusCheck {
    $s = $script:St
    if ($s.Pending -gt 0) { return }
    $u = $script:Ui
    $u.BtnStRefresh.IsEnabled = $false
    $u.TxtStBannerSub.Text = 'Comprobando…'
    $s.Pending = 2
    $s.NewOfficial = $null; $s.NewProbes = $null
    [void](Start-CsJob -Script $script:StatusOfficialJob -Arguments @(, $s.Sources) -OnDone {
            param($res, $err)
            $script:St.NewOfficial = @($res | Where-Object { $_ -is [CloudSpeed.StatusRow] })
            Complete-CsStatusPart
        })
    [void](Start-CsJob -Script $script:StatusProbeJob -Arguments @(, $s.Targets) -OnDone {
            param($res, $err)
            $script:St.NewProbes = @($res | ForEach-Object { $_ })
            Complete-CsStatusPart
        })
}

function Complete-CsStatusPart {
    $s = $script:St
    $s.Pending--
    if ($s.Pending -gt 0) { return }
    $s.Official = @($s.NewOfficial | Sort-Object @{e = { -$_.Level } }, Provider, Service)
    $s.Probes = @($s.NewProbes | Sort-Object @{e = { -$_.Level } }, Provider, Service)
    $s.Last = Get-Date
    $u = $script:Ui
    $u.GridStOfficial.ItemsSource = $s.Official
    $u.GridStProbe.ItemsSource = $s.Probes
    $u.BtnStRefresh.IsEnabled = $true
    Update-CsStatusBanner
    if ($u.ChkStHistory.IsChecked) { Save-CsStatusHistory }
    if ($u.ChkStAuto.IsChecked) { Set-CsStatusNext }
}

function Update-CsStatusBanner {
    $s = $script:St; $u = $script:Ui
    $providers = @('Microsoft Azure', 'Microsoft 365', 'AWS', 'Google', 'GitHub', 'Cloudflare')
    $ref = @($s.Probes | Where-Object Provider -eq 'Referencia')
    $realProbes = @($s.Probes | Where-Object Provider -ne 'Referencia')
    $failed = @($realProbes | Where-Object { $_.Level -ge 3 })
    $msgs = @(); $worst = 0
    if ($realProbes.Count -and $failed.Count -ge [math]::Ceiling($realProbes.Count * 0.7) -and ($ref | Where-Object { $_.Level -ge 3 })) {
        $msgs += 'Casi nada responde, tampoco el sitio de control: parece un problema de tu conexión a Internet, DNS o proxy, no de los proveedores.'
        $worst = 3
    }
    else {
        foreach ($p in $providers) {
            $off = @($s.Official | Where-Object Provider -eq $p)
            $prb = @($s.Probes | Where-Object Provider -eq $p)
            $offLvl = ($off | Where-Object { $_.Level -ge 0 } | Measure-Object Level -Maximum).Maximum
            $offDown = [bool]($off | Where-Object { $_.Level -lt 0 })
            $prbBad = @($prb | Where-Object { $_.Level -ge 2 })
            $names = ($prbBad | ForEach-Object Service) -join ', '
            if ($prbBad.Count -and $offDown) { $msgs += "$p`: no responde ($names) y su página de estado tampoco. Posible caída global: consulta las cuentas oficiales en redes sociales (Azure Support, Microsoft 365 Status, AWS Support)."; $worst = 3 }
            elseif ($prbBad.Count -and $offLvl -ge 2) { $msgs += "$p`: incidencia confirmada. El proveedor la ha publicado y también se nota desde tu red ($names)."; $worst = [math]::Max($worst, 3) }
            elseif ($prbBad.Count) { $msgs += "$p`: $names no responde desde tu red, pero su página de estado no informa de nada. Puede ser una caída que aún no han publicado o un problema local (proxy, firewall, VPN)."; $worst = [math]::Max($worst, 2) }
            elseif ($offLvl -ge 2) { $msgs += "$p`: publica una incidencia, pero desde tu red los servicios clave responden; puede afectar a otras regiones o servicios."; $worst = [math]::Max($worst, 2) }
            elseif ($offDown) { $msgs += "$p`: no se pudo leer su página de estado, pero sus servicios responden desde tu red."; $worst = [math]::Max($worst, 1) }
            elseif ($offLvl -eq 1) { $worst = [math]::Max($worst, 1) }
        }
    }
    $color = @{ 0 = '#22C55E'; 1 = '#3B82F6'; 2 = '#F59E0B'; 3 = '#EF4444' }[$worst]
    $u.DotStBanner.Fill = (Get-CsBrush $color)
    if ($msgs.Count -eq 0) {
        $u.TxtStBanner.Text = 'Todo operativo: los proveedores no publican incidencias y sus servicios responden desde tu red.'
    }
    else { $u.TxtStBanner.Text = $msgs -join "`n" }
    $okOff = @($s.Official | Where-Object Level -eq 0).Count
    $okPrb = @($realProbes | Where-Object Level -eq 0).Count
    $u.TxtStBannerSub.Text = "Comprobado a las {0:HH:mm:ss} · fuentes oficiales operativas: {1} de {2} · servicios que responden desde tu red: {3} de {4}" -f $s.Last, $okOff, $s.Official.Count, $okPrb, $realProbes.Count
    if ($worst -ge 2 -and $script:G.Page -ne 'Estado') { Set-CsStatus ('⚠ Estado de servicios: ' + ($msgs | Select-Object -First 1)) }
}

function Save-CsStatusHistory {
    try {
        $rows = @($script:St.Official) + @($script:St.Probes) | ForEach-Object {
            $d = [string]$_.Detail; if ($d -and '=+-@' -match [regex]::Escape($d[0])) { $d = "'" + $d }
            [pscustomobject]@{ Fecha = $_.Time.ToString('yyyy-MM-dd HH:mm:ss'); Fuente = $_.Source; Proveedor = $_.Provider; Servicio = $_.Service; Nivel = $_.Level
                Estado = $_.State; Detalle = $d; DNS_ms = $_.DnsMs; Conexion_ms = $_.ConnectMs; HTTPS_ms = $_.HttpMs; Codigo = $_.Code; Equipo = (Get-CsMachine) }
        }
        $rows | Export-Csv -Path (Join-Path (Get-CsFolder Datos) 'Estado.csv') -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    catch { Set-CsStatus "No se pudo guardar el histórico de estado: $($_.Exception.Message)" }
}

# Comprobación automática: se llama en cada ciclo del temporizador, esté abierta o no la sección
function Invoke-CsStatusAuto {
    if (-not $script:St -or -not $script:St.Next -or $script:St.Pending -gt 0) { return }
    if ((Get-Date) -ge $script:St.Next) { $script:St.Next = $null; Start-CsStatusCheck }
}

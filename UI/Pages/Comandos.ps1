# Comandos.ps1 - Generador de comandos PsPing, PowerShell y curl, y prueba rápida de una región.

function Initialize-CsPageComandos {
    $u = $script:Ui
    $regs = @($script:Cat.Regions | Where-Object HasEndpoint | Sort-Object Cloud, Name)
    $u.CmbCmdRegion.ItemsSource = $regs
    $u.CmbCmdRegion.DisplayMemberPath = 'Label'
    $sel = $script:Rows | Where-Object { $null -ne $_.P50 } | Sort-Object SortKey | Select-Object -First 1
    $u.CmbCmdRegion.SelectedItem = $(if ($sel) { $sel.Info } else { $regs | Where-Object Code -eq 'westeurope' | Select-Object -First 1 })
    foreach ($c in 'CmbCmdRegion') { $u[$c].Add_SelectionChanged({ Update-CsCommands }) }
    foreach ($t in 'TxtCmdN', 'TxtCmdW', 'TxtCmdPort') { $u[$t].Add_TextChanged({ Update-CsCommands }) }
    $u.BtnCopyPsping.Add_Click({ Copy-CsText $script:Ui.TxtPsping.Text 'Comando PsPing' })
    $u.BtnCopyTnc.Add_Click({ Copy-CsText $script:Ui.TxtTnc.Text 'Comando' })
    $u.BtnCopyPsLoop.Add_Click({ Copy-CsText $script:Ui.TxtPsLoop.Text 'Comando' })
    $u.BtnCopyCurl.Add_Click({ Copy-CsText $script:Ui.TxtCurl.Text 'Comando curl' })
    $u.BtnPsTools.Add_Click({ Start-Process 'https://learn.microsoft.com/sysinternals/downloads/psping' })
    $u.BtnCmdTest.Add_Click({ Start-CsCommandTest })
    Update-CsCommands
}

function Get-CsCmdInt([string]$t, [int]$def, [int]$min, [int]$max) {
    $v = 0; if ([int]::TryParse($t, [ref]$v)) { return [math]::Min($max, [math]::Max($min, $v)) } return $def
}

function Update-CsCommands {
    $u = $script:Ui
    $r = $u.CmbCmdRegion.SelectedItem
    if (-not $r) { return }
    $n = Get-CsCmdInt $u.TxtCmdN.Text 20 1 1000
    $w = Get-CsCmdInt $u.TxtCmdW.Text 5 0 100
    $port = Get-CsCmdInt $u.TxtCmdPort.Text 443 1 65535
    $h = $r.Host
    $u.TxtPsping.Text = "psping.exe -accepteula -n $n -w $w ${h}:$port"
    $u.TxtTnc.Text = "Test-NetConnection -ComputerName $h -Port $port -InformationLevel Detailed"
    $u.TxtPsLoop.Text = "`$ip = [Net.Dns]::GetHostAddresses('$h') | ? AddressFamily -eq 'InterNetwork' | select -First 1; " +
    "1..$w | % { `$c = [Net.Sockets.TcpClient]::new(); `$c.Connect(`$ip, $port); `$c.Close() }; " +
    "`$t = 1..$n | % { `$c = [Net.Sockets.TcpClient]::new(); `$s = [Diagnostics.Stopwatch]::StartNew(); `$c.Connect(`$ip, $port); `$s.Stop(); `$c.Close(); `$s.Elapsed.TotalMilliseconds } | sort; " +
    "'{0}  mín {1:0.0} ms · mediana {2:0.0} ms · máx {3:0.0} ms' -f '$h', `$t[0], `$t[[int](`$t.Count/2)], `$t[-1]"
    $u.TxtCurl.Text = "curl -so /dev/null -w ""dns %{time_namelookup}s  tcp %{time_connect}s  tls %{time_appconnect}s  total %{time_total}s\n"" https://$h/"
}

function Start-CsCommandTest {
    $u = $script:Ui
    $r = $u.CmbCmdRegion.SelectedItem
    if (-not $r) { return }
    $n = Get-CsCmdInt $u.TxtCmdN.Text 20 1 200
    $u.BtnCmdTest.IsEnabled = $false
    $u.TxtCmdResult.Text = "Midiendo $($r.Label) ($n muestras)…"
    [void](Start-CsJob -Status "Midiendo $($r.Label)…" -Arguments @($r, $n) -Script {
            param($r, $n)
            $e = New-Object CloudSpeed.ProbeEngine
            $e.Samples = $n; $e.MeasureTls = $true; $e.GapMs = 50
            [CloudSpeed.Runner]::RunBlocking($e, [CloudSpeed.RegionInfo[]]@($r), 1, $null)
        } -OnDone {
            param($res, $err)
            $u = $script:Ui
            $u.BtnCmdTest.IsEnabled = $true
            if ($err) { $u.TxtCmdResult.Text = "Error: $err"; return }
            $s = @($res)
            $ok = @($s | Where-Object Ok | ForEach-Object TcpMs | Sort-Object)
            $tls = @($s | Where-Object { $_.Ok -and -not [double]::IsNaN($_.TlsMs) } | ForEach-Object TlsMs | Sort-Object)
            if ($ok.Count -eq 0) { $u.TxtCmdResult.Text = 'Sin respuesta: ' + (@($s | ForEach-Object Error | Select-Object -Unique) -join ', '); return }
            $es = [Globalization.CultureInfo]'es-ES'
            $med = $ok[[int][math]::Floor(($ok.Count - 1) / 2)]
            $hist = ($ok | ForEach-Object { '█' * [math]::Max(1, [int]($_ / [math]::Max(1, $ok[-1]) * 30)) + ' ' + $_.ToString('0.0', $es) }) -join [Environment]::NewLine
            $u.TxtCmdResult.Text = ("{0} · IP {1}{2}TCP: mín {3:0.0} ms · mediana {4:0.0} ms · máx {5:0.0} ms · {6}/{7} respuestas{2}TLS (saludo): mediana {8}{2}{2}{9}" -f
                $s[0].Region.Label, $s[0].Ip, [Environment]::NewLine, $ok[0], $med, $ok[-1], $ok.Count, $s.Count,
                $(if ($tls.Count) { $tls[[int][math]::Floor(($tls.Count - 1) / 2)].ToString('0.0', $es) + ' ms' } else { '—' }), $hist)
            Set-CsStatus "Medición de $($s[0].Region.Label) terminada."
        })
}

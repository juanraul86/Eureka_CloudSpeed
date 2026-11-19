# RegionRegion.ps1 - Latencia publicada por Microsoft entre regiones de Azure.

function Initialize-CsPageRegionRegion {
    $u = $script:Ui
    $m = Get-CsJson 'region-latency.json'
    $ref = (Get-CsJson 'azure-regions.json').regions | Where-Object cloud -eq 'Global'
    $loc = @{}; foreach ($r in $ref) { $loc[$r.name] = "$($r.location)" }
    $rows = @{}
    foreach ($r in $m.rows) { $rows[$r.source] = $r.latencies }
    $script:R2R = @{ Dest = @($m.destinations); Rows = $rows; Loc = $loc; Current = @() }
    $u.CmbR2RSource.ItemsSource = @($rows.Keys | Sort-Object)
    $def = $(if ($rows.ContainsKey('Spain Central')) { 'Spain Central' } else { @($rows.Keys | Sort-Object)[0] })
    $u.CmbR2RSource.SelectedItem = $def
    $u.CmbR2RSource.Add_SelectionChanged({ Update-CsR2R })
    $u.CmbR2RMax.Add_SelectionChanged({ Update-CsR2R })
    $u.TxtR2RSearch.Add_TextChanged({ Update-CsR2R })
    $u.ScrollR2R.Add_SizeChanged({ Update-CsR2RChart })
    $u.BtnR2RCsv.Add_Click({
            Export-CsObjects ($script:R2R.Current | Select-Object Rank, @{n = 'Origen'; e = { $script:Ui.CmbR2RSource.SelectedItem } }, @{n = 'Destino'; e = { $_.Destination } }, @{n = 'Ubicacion'; e = { $_.Location } }, @{n = 'RTT_ms'; e = { $_.Ms } }) ('Latencia_desde_{0}.csv' -f ($script:Ui.CmbR2RSource.SelectedItem -replace '\s', ''))
        })
    $u.BtnR2RExcel.Add_Click({ Export-CsR2RMatrix })
    Update-CsR2R
}

function Update-CsR2R {
    $u = $script:Ui
    $src = [string]$u.CmbR2RSource.SelectedItem
    if (-not $src) { return }
    $lat = $script:R2R.Rows[$src]
    $max = [int]$u.CmbR2RMax.SelectedItem.Tag
    $q = $u.TxtR2RSearch.Text.Trim()
    $list = for ($i = 0; $i -lt $script:R2R.Dest.Count; $i++) {
        $d = $script:R2R.Dest[$i]; $v = $lat[$i]
        if ($null -eq $v -or $d -eq $src) { continue }
        [pscustomobject]@{ Destination = $d; Location = $script:R2R.Loc[$d]; Ms = [int]$v }
    }
    $list = @($list | Sort-Object Ms)
    $rank = 0; foreach ($x in $list) { $rank++; $x | Add-Member Rank $rank }
    $shown = @($list | Where-Object { ($max -eq 0 -or $_.Ms -le $max) -and (-not $q -or $_.Destination -like "*$q*" -or $_.Location -like "*$q*") })
    $script:R2R.Current = $shown
    $u.GridR2R.ItemsSource = $shown
    $best = @($list | Select-Object -First 3 | ForEach-Object { "$($_.Destination) ($($_.Ms) ms)" }) -join ' · '
    $u.TxtR2RBest.Text = "Más cercanas a $src`: $best    ·    mostrando $($shown.Count) de $($list.Count) regiones"
    Update-CsR2RChart
}

function Update-CsR2RChart {
    $u = $script:Ui
    $cur = @($script:R2R.Current)
    $labels = New-Object 'System.Collections.Generic.List[string]'
    $vals = New-Object 'System.Collections.Generic.List[double]'
    $cols = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in $cur) { $labels.Add($x.Destination); $vals.Add($x.Ms); $cols.Add([CloudSpeed.Stats]::Level([double]$x.Ms)) }
    [CloudSpeed.Charts]::HBars($u.CanvasR2R, $labels, $vals, $cols, $script:G.ChartTheme, [math]::Max(300, $u.ScrollR2R.ActualWidth - 40), 'ms')
}

function Show-CsPageRegionRegion { if ($script:R2R) { Update-CsR2RChart } }

function Export-CsR2RMatrix {
    $f = Save-CsFileDialog 'Latencia_entre_regiones_Azure.xlsx' 'Libro de Excel (*.xlsx)|*.xlsx'
    if (-not $f) { return }
    $wb = New-Object CloudSpeed.XWorkbook
    $sh = $wb.AddSheet('Matriz')
    $sh.Add([object[]]@((New-Object CloudSpeed.XCell 'Latencia entre regiones de Azure (mediana de ida y vuelta, ms) · origen en filas, destino en columnas', 5))) | Out-Null
    $sh.Add([object[]]@((New-Object CloudSpeed.XCell 'Fuente: estadísticas publicadas por Microsoft (Azure network round-trip latency statistics).', 8))) | Out-Null
    $hdr = @('Origen \ Destino') + $script:R2R.Dest
    $h0 = $sh.Add([object[]]$hdr)
    foreach ($src in ($script:R2R.Rows.Keys | Sort-Object)) {
        $row = @($src) + @($script:R2R.Rows[$src] | ForEach-Object { if ($null -eq $_) { $null } else { [double]$_ } })
        [void]$sh.Add([object[]]$row)
    }
    $last = $sh.Rows.Count - 1
    $sh.ColorScales.Add(('B{0}:{1}{2}' -f ($h0 + 2), [CloudSpeed.XWorkbook]::Col($hdr.Count - 1), ($last + 1)))
    $sh.FreezeRows = $h0 + 1
    $sh.Widths[0] = 24; for ($i = 1; $i -lt $hdr.Count; $i++) { $sh.Widths[$i] = 9 }
    $t = New-Object CloudSpeed.XTable; $t.Name = 'TablaLatencia'; $t.Row0 = $h0; $t.Col0 = 0; $t.Row1 = $last; $t.Col1 = $hdr.Count - 1
    $sh.Tables.Add($t)
    try { $wb.Save($f); Set-CsStatus "Matriz guardada: $f"; Invoke-Item $f } catch { Show-CsMessage "No se pudo guardar:`n$($_.Exception.Message)" 'Error' }
}

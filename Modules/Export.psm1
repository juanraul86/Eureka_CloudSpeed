# Export.psm1 - Exportaciones: Excel con gráficos, CSV, informe HTML y paquete para Power BI Desktop.

function Get-CsStamp { (Get-Date).ToString('yyyyMMdd_HHmmss') }

function Get-CsSafeName([string]$s) { ($s -replace '[\\/:*?"<>|]', '_').Trim() }

function Export-CsExcel {
    param($Rows, $Catalog, $Meta, [string]$Label, [string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-CsFolder Exportaciones) ('Latencia_{0}_{1}.xlsx' -f (Get-CsSafeName (Get-CsMachine)), (Get-CsStamp)) }
    [CloudSpeed.ExcelReport]::Build($Path, [CloudSpeed.RegionRow[]]@($Rows), $Catalog.Geos, $Catalog.Clouds, $Catalog.CloudColors, $Meta, (Get-CsMachine), $Label)
    return $Path
}

function Export-CsCsv {
    param($Rows, [string]$Label, [string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-CsFolder Exportaciones) ('Mediciones_{0}_{1}.csv' -f (Get-CsSafeName (Get-CsMachine)), (Get-CsStamp)) }
    $samples = [CloudSpeed.Sample[]]@($Rows | ForEach-Object { $_.Samples } | Sort-Object Time)
    [CloudSpeed.Store]::WriteSamples($Path, $samples, (Get-CsMachine), $Label)
    return $Path
}

function Export-CsPowerBI {
    <# Construye, con TODO el histórico de Datos\, un libro de Excel con las tablas Mediciones, Regiones y
       Sesiones (modelo en estrella) en una ruta fija, más un archivo .pbids que lo abre en Power BI Desktop
       y la guía con las medidas DAX. Al volver a exportar se sobrescribe y en Power BI basta con Actualizar. #>
    param($Catalog)
    $out = Join-Path (Get-CsFolder Exportaciones) 'PowerBI'
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $data = Get-CsFolder Datos
    [CloudSpeed.Store]::WriteRegions((Join-Path $data 'Regiones.csv'), $Catalog.Regions)
    $wb = Join-Path $out 'Eureka_CloudSpeed_PowerBI.xlsx'
    $n = [CloudSpeed.PowerBiBook]::Build($data, $wb, $Catalog.Regions)

    $pbids = [ordered]@{
        version     = '0.1'
        connections = @(@{ details = @{ protocol = 'file'; address = @{ path = $wb } }; options = @{}; mode = 'Import' })
    }
    [IO.File]::WriteAllText((Join-Path $out 'Abrir_en_Power_BI.pbids'), ($pbids | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))

    # Consultas de Power Query para leer directamente los CSV del histórico (alternativa al Excel)
    $m = Get-Content (Join-Path (Get-CsRoot) 'PowerBI\Consultas.pq') -Raw -Encoding UTF8
    $m = $m.Replace('__CARPETA_DATOS__', $data.Replace('"', '""'))
    [IO.File]::WriteAllText((Join-Path $out 'Consultas.pq'), $m, (New-Object Text.UTF8Encoding $true))
    foreach ($f in 'Medidas.dax', 'Guia-Power-BI.html') { Copy-Item (Join-Path (Get-CsRoot) "PowerBI\$f") $out -Force }
    [pscustomobject]@{ Folder = $out; Workbook = $wb; Rows = $n }
}

function ConvertTo-CsHtml([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

function Export-CsHtml {
    param($Rows, $Catalog, $Meta, [string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-CsFolder Exportaciones) ('Informe_{0}_{1}.html' -f (Get-CsSafeName (Get-CsMachine)), (Get-CsStamp)) }
    $es = [Globalization.CultureInfo]'es-ES'
    $measured = @($Rows | Where-Object { $_.Count -gt 0 } | Sort-Object SortKey)
    $ok = @($measured | Where-Object { $null -ne $_.P50 })
    $top = @($ok | Select-Object -First 30)
    $raw = [math]::Max(1, ($top | ForEach-Object { if ($null -ne $_.P95) { $_.P95 } else { $_.P50 } } | Measure-Object -Maximum).Maximum)
    $exp = [math]::Pow(10, [math]::Floor([math]::Log10($raw)))
    $max = (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 | ForEach-Object { $_ * $exp } | Where-Object { $_ -ge $raw } | Select-Object -First 1)
    $f = { param($v, $fmt = '0.0') if ($null -eq $v) { '—' } else { ([double]$v).ToString($fmt, $es) } }

    # Gráfico de barras en SVG (P50 + bigote P95)
    $rowH = 26; $lw = 250; $pw = 560; $h = 30 + $top.Count * $rowH
    $svg = New-Object Text.StringBuilder
    [void]$svg.Append("<svg viewBox='0 0 $($lw + $pw + 90) $h' role='img' aria-label='Ranking de latencia'>")
    $nd = if ($max % 5 -eq 0) { 5 } else { 4 }
    for ($i = 0; $i -le $nd; $i++) {
        $x = $lw + $pw * $i / $nd; $v = $max * $i / $nd
        [void]$svg.Append("<line x1='$x' y1='22' x2='$x' y2='$h' class='grid'/><text x='$x' y='14' class='axis' text-anchor='middle'>$($v.ToString('0', $es)) ms</text>")
    }
    $i = 0
    foreach ($r in $top) {
        $y = 26 + $i * $rowH; $i++
        $w = [math]::Max(2, $r.P50 / $max * $pw)
        $col = $Catalog.CloudColors[$r.Cloud]
        [void]$svg.Append("<text x='0' y='$($y + 13)' class='lbl'>$i. $(ConvertTo-CsHtml $r.Label)</text>")
        [void]$svg.Append("<rect x='$lw' y='$($y + 3)' width='$($w.ToString('0.#', [Globalization.CultureInfo]::InvariantCulture))' height='16' rx='3' fill='$col'><title>$(ConvertTo-CsHtml $r.Label): P50 $(& $f $r.P50) ms · P95 $(& $f $r.P95) ms</title></rect>")
        if ($null -ne $r.P95 -and $r.P95 -gt $r.P50) {
            $x95 = $lw + [math]::Min($pw, $r.P95 / $max * $pw)
            $inv = [Globalization.CultureInfo]::InvariantCulture
            [void]$svg.Append("<line x1='$(($lw + $w).ToString('0.#', $inv))' y1='$($y + 11)' x2='$($x95.ToString('0.#', $inv))' y2='$($y + 11)' class='wh'/><line x1='$($x95.ToString('0.#', $inv))' y1='$($y + 6)' x2='$($x95.ToString('0.#', $inv))' y2='$($y + 16)' class='wh'/>")
        }
        [void]$svg.Append("<text x='$($lw + $pw + 8)' y='$($y + 14)' class='val'>$(& $f $r.P50) ms</text>")
    }
    [void]$svg.Append('</svg>')

    $metaHtml = ($Meta | ForEach-Object { "<div><span>$(ConvertTo-CsHtml $_.Key)</span><b>$(ConvertTo-CsHtml $_.Value)</b></div>" }) -join ''
    $cards = foreach ($c in $Catalog.Clouds) {
        $b = $ok | Where-Object Cloud -eq $c | Select-Object -First 1
        if ($b) { "<div class='card' style='border-top:3px solid $($Catalog.CloudColors[$c])'><span>Mejor región $c</span><b>$(& $f $b.P50) ms</b><small>$(ConvertTo-CsHtml $b.Name) · $(ConvertTo-CsHtml $b.Info.City)</small></div>" }
    }
    $trs = foreach ($r in $measured) {
        $lvl = [CloudSpeed.Stats]::Level($(if ($null -ne $r.P50) { [double]$r.P50 } else { [double]::NaN }))
        "<tr><td class='n'>$($r.Rank)</td><td><i style='background:$($Catalog.CloudColors[$r.Cloud])'></i>$($r.Cloud)</td><td><b>$(ConvertTo-CsHtml $r.Name)</b> <small>$($r.Code)</small></td><td>$(ConvertTo-CsHtml $r.Geo)</td><td>$(ConvertTo-CsHtml $r.City)</td>" +
        "<td class='n'><span class='dot' style='background:$lvl'></span>$(& $f $r.P50)</td><td class='n'>$(& $f $r.P95)</td><td class='n'>$(& $f $r.Min)</td><td class='n'>$(& $f $r.Avg)</td><td class='n'>$(& $f $r.Jitter)</td><td class='n'>$(if ($null -ne $r.Loss) { ([double]$r.Loss).ToString('0.#%', $es) } else { '—' })</td><td class='n'>$($r.Count)</td></tr>"
    }

    $html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Latencia a regiones cloud</title>
<style>
:root{--bg:#F3F4F6;--sf:#fff;--bd:#E5E7EB;--tx:#1F2937;--mu:#6B7280;--ac:#0F6CBD}
@media (prefers-color-scheme:dark){:root{--bg:#111318;--sf:#1B1E25;--bd:#2D323C;--tx:#E6E8EC;--mu:#9AA3B2;--ac:#3B8EE0}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
header{background:var(--ac);color:#fff;padding:18px 24px}header h1{margin:0;font-size:22px}header p{margin:2px 0 0;opacity:.85}
main{max-width:1200px;margin:0 auto;padding:18px 16px 40px}
.meta{display:flex;flex-wrap:wrap;gap:8px 22px;margin-bottom:14px}.meta span{color:var(--mu);margin-right:6px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-bottom:16px}
.card,section{background:var(--sf);border:1px solid var(--bd);border-radius:8px;padding:14px 16px}
.card span,.card small{display:block;color:var(--mu)}.card b{font-size:24px}
section{margin-bottom:16px;overflow-x:auto}h2{font-size:16px;margin:0 0 10px}
svg{width:100%;min-width:640px;height:auto;font-size:12px}svg .grid{stroke:var(--bd)}svg .axis{fill:var(--mu)}svg .lbl{fill:var(--tx)}svg .val{fill:var(--tx);font-weight:600}svg .wh{stroke:var(--mu);stroke-width:1.2}
table{border-collapse:collapse;width:100%;min-width:820px}th,td{padding:6px 8px;border-bottom:1px solid var(--bd);text-align:left;white-space:nowrap}
th{color:var(--mu);font-weight:600;font-size:12px}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
td i{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
small{color:var(--mu)}footer{color:var(--mu);font-size:12px}
</style></head><body>
<header><h1>Latencia a regiones de Azure y AWS</h1><p>Medido desde este equipo con Eureka_CloudSpeed</p></header>
<main>
<div class="meta">$metaHtml</div>
<div class="cards">$($cards -join '')</div>
<section><h2>Las $($top.Count) regiones más rápidas</h2><p><small>Barra = mediana (P50). Línea = percentil 95.</small></p>$svg</section>
<section><h2>Todas las regiones medidas</h2>
<table><thead><tr><th class="n">#</th><th>Nube</th><th>Región</th><th>Geografía</th><th>Ubicación</th><th class="n">P50 (ms)</th><th class="n">P95</th><th class="n">Mín</th><th class="n">Media</th><th class="n">Jitter</th><th class="n">Pérdida</th><th class="n">n</th></tr></thead>
<tbody>$($trs -join "`n")</tbody></table></section>
<footer>Latencia = tiempo de conexión TCP al puerto 443 del endpoint regional (aprox. un viaje de ida y vuelta). Verde &lt; 50 ms · lima &lt; 100 ms · ámbar &lt; 175 ms · rojo ≥ 175 ms.</footer>
</main></body></html>
"@
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
    return $Path
}

Export-ModuleMember -Function Export-Cs*

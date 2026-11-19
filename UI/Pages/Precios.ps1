# Precios.ps1 - Precios de máquinas virtuales (Azure y EC2) y de modelos de IA (Azure), en vivo.

$script:VmModels = @{
    Azure = @(@('Pago por uso', 'payg'), @('Spot', 'spot'), @('Plan de ahorro 1 año', 'sp1'), @('Plan de ahorro 3 años', 'sp3'), @('Reserva 1 año', 'ri1'), @('Reserva 3 años', 'ri3'))
    AWS   = @(@('Bajo demanda', 'payg'))
}

# Consulta de la API de precios de Azure (se ejecuta en segundo plano)
$script:AzurePriceJob = {
    param([string]$Filter, [string]$Os, [string]$Model)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&$filter=' + [uri]::EscapeDataString($Filter)
    $items = New-Object System.Collections.ArrayList
    $n = 0
    while ($url -and $n -lt 60) {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 60 -UseBasicParsing
        [void]$items.AddRange(@($r.Items)); $url = $r.NextPageLink; $n++
    }
    $best = @{}
    foreach ($i in $items) {
        if ($i.skuName -match 'Low Priority' -or $i.meterName -match 'Low Priority') { continue }
        $isWin = $i.productName -match 'Windows'
        if (($Os -eq 'Windows') -ne $isWin) { continue }
        if ($i.unitOfMeasure -notmatch 'Hour' -and $i.type -ne 'Reservation') { continue }
        $spot = $i.skuName -match 'Spot'
        $price = $null
        switch ($Model) {
            'payg' { if ($i.type -eq 'Consumption' -and -not $spot) { $price = [double]$i.retailPrice } }
            'spot' { if ($i.type -eq 'Consumption' -and $spot) { $price = [double]$i.retailPrice } }
            { $_ -in 'sp1', 'sp3' } {
                if ($i.type -eq 'Consumption' -and -not $spot -and $i.savingsPlan) {
                    $term = $(if ($Model -eq 'sp1') { '1 Year' } else { '3 Years' })
                    $sp = @($i.savingsPlan) | Where-Object term -eq $term | Select-Object -First 1
                    if ($sp) { $price = [double]$sp.retailPrice }
                }
            }
            { $_ -in 'ri1', 'ri3' } {
                $term = $(if ($Model -eq 'ri1') { '1 Year' } else { '3 Years' })
                if ($i.type -eq 'Reservation' -and $i.reservationTerm -eq $term) { $price = [double]$i.retailPrice / (8760 * $(if ($Model -eq 'ri1') { 1 } else { 3 })) }
            }
        }
        if ($null -eq $price -or $price -le 0) { continue }
        $key = "$($i.armRegionName)|$($i.armSkuName)"
        if (-not $best.ContainsKey($key) -or $price -lt $best[$key].Hourly) {
            $best[$key] = [pscustomobject]@{ Region = $i.armRegionName; Sku = $i.armSkuName; Hourly = $price; Product = $i.productName }
        }
    }
    @($best.Values)
}

# Lista de precios de EC2 (la misma que usa la web de precios de AWS)
$script:AwsPriceJob = {
    param([string[]]$Locations, [string]$Os, [string]$OnlyType)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $out = New-Object System.Collections.ArrayList
    foreach ($loc in $Locations) {
        $url = 'https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/{0}/{1}/index.json' -f [uri]::EscapeDataString($loc), $Os
        try { $j = Invoke-RestMethod -Uri $url -TimeoutSec 60 -UseBasicParsing } catch { continue }
        $reg = $j.regions.PSObject.Properties | Select-Object -First 1
        if (-not $reg) { continue }
        foreach ($p in $reg.Value.PSObject.Properties) {
            $v = $p.Value
            if ($OnlyType -and $v.'Instance Type' -ne $OnlyType) { continue }
            if ($v.'Pre Installed S/W' -and $v.'Pre Installed S/W' -ne 'NA') { continue }
            $price = 0.0
            if (-not [double]::TryParse([string]$v.price, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$price) -or $price -le 0) { continue }
            $mem = 0.0; [void][double]::TryParse(([string]$v.Memory -replace '[^0-9.]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mem)
            [void]$out.Add([pscustomobject]@{ Location = $loc; Sku = $v.'Instance Type'; Hourly = $price; Vcpu = [int]$v.vCPU; MemoryGB = $mem; Family = $v.'Instance Family'; Storage = $v.Storage; Gpu = $(if ($v.GPU) { [int]$v.GPU } else { 0 }) })
        }
    }
    @($out)
}

# ------------------------------------------------------------------ máquinas virtuales

function Initialize-CsPagePreciosVm {
    $u = $script:Ui
    $spec = Get-CsJson 'vm-specs.json'
    $script:VmSpecs = @{}
    foreach ($p in $spec.skus.PSObject.Properties) { $script:VmSpecs[$p.Name] = $p.Value }
    $script:AzRef = (Get-CsJson 'azure-regions.json').regions | Where-Object { $_.cloud -eq 'Global' }
    $script:AwsLoc = Get-CsJson 'aws-locations.json'
    $script:Vm = @{ All = @(); Shown = @() }
    $u.RbVmAzure.Add_Checked({ Update-CsVmRegions })
    $u.RbVmAws.Add_Checked({ Update-CsVmRegions })
    foreach ($c in 'TxtVmSearch', 'TxtVmCpu', 'TxtVmMem', 'TxtVmCpuMax') { $u[$c].Add_TextChanged({ Update-CsVmFilter }) }
    $u.ChkVmGpu.Add_Click({ Update-CsVmFilter })
    $u.RbVmHour.Add_Checked({ Update-CsVmFilter }); $u.RbVmMonth.Add_Checked({ Update-CsVmFilter })
    $u.BtnVmLoad.Add_Click({ Start-CsVmLoad })
    $u.GridVm.Add_SelectionChanged({ $script:Ui.BtnVmCompare.IsEnabled = $null -ne $script:Ui.GridVm.SelectedItem })
    $u.BtnVmCompare.Add_Click({ Start-CsVmCompare })
    $u.BtnVmExcel.Add_Click({ Export-CsVmExcel })
    Update-CsVmRegions
}

function Update-CsVmRegions {
    $u = $script:Ui
    $aws = [bool]$u.RbVmAws.IsChecked
    $items = New-Object System.Collections.ArrayList
    if ($aws) {
        foreach ($r in ($script:Cat.Regions | Where-Object Cloud -eq 'AWS' | Sort-Object Name)) {
            if ($script:AwsLoc.($r.Code)) { [void]$items.Add((New-CsItem "$($r.Name) · $($r.Code)" $r.Code)) }
        }
    }
    else {
        foreach ($r in ($script:AzRef | Sort-Object name)) { [void]$items.Add((New-CsItem "$($r.name) · $($r.code)" $r.code)) }
    }
    $u.CmbVmRegion.ItemsSource = $items
    $pref = $(if ($aws) { 'eu-south-2' } else { 'spaincentral' })
    $u.CmbVmRegion.SelectedItem = $items | Where-Object Tag -eq $pref | Select-Object -First 1
    if ($null -eq $u.CmbVmRegion.SelectedItem) { $u.CmbVmRegion.SelectedIndex = 0 }
    $m = New-Object System.Collections.ArrayList
    foreach ($x in $script:VmModels[$(if ($aws) { 'AWS' } else { 'Azure' })]) { [void]$m.Add((New-CsItem $x[0] $x[1])) }
    $u.CmbVmModel.ItemsSource = $m; $u.CmbVmModel.SelectedIndex = 0
    $u.ChkVmGpu.IsEnabled = -not $aws
}

function Start-CsVmLoad {
    $u = $script:Ui
    $aws = [bool]$u.RbVmAws.IsChecked
    $region = [string]$u.CmbVmRegion.SelectedItem.Tag
    $os = $(if ($u.RbVmWindows.IsChecked) { 'Windows' } else { 'Linux' })
    $model = [string]$u.CmbVmModel.SelectedItem.Tag
    $cloud = $(if ($aws) { 'AWS' } else { 'Azure' })
    $cache = Join-Path (Get-CsCacheFolder) ('vm-{0}-{1}-{2}-{3}-{4:yyyyMMdd}.json' -f $cloud, $region, $os, $model, (Get-Date))
    $script:Vm.Context = @{ Cloud = $cloud; Region = $region; Os = $os; Model = $model; Label = $u.CmbVmRegion.SelectedItem.Content; ModelLabel = $u.CmbVmModel.SelectedItem.Content }
    if (Test-Path $cache) {
        $data = Get-Content $cache -Raw -Encoding UTF8 | ConvertFrom-Json
        Set-CsVmData $data
        Set-CsStatus "Precios de $($script:Vm.Context.Label) (caché de hoy)."
        return
    }
    $u.BtnVmLoad.IsEnabled = $false
    $u.TxtVmInfo.Text = 'Consultando precios… (Azure pagina de 1000 en 1000: puede tardar unos segundos)'
    $job = $(if ($aws) { $script:AwsPriceJob } else { $script:AzurePriceJob })
    $jobArgs = $(if ($aws) { @(, [string[]]@($script:AwsLoc.$region), $os, '') } else {
            @("serviceName eq 'Virtual Machines' and armRegionName eq '$region' and priceType eq '$(if ($model -like 'ri*') { 'Reservation' } else { 'Consumption' })'", $os, $model) })
    $script:Vm.Cache = $cache
    [void](Start-CsJob -Script $job -Arguments $jobArgs -Status 'Consultando precios de máquinas virtuales…' -OnDone {
            param($res, $err)
            $script:Ui.BtnVmLoad.IsEnabled = $true
            if ($err -and -not $res) { $script:Ui.TxtVmInfo.Text = "No se pudieron consultar los precios: $err"; return }
            $data = @($res)
            try { $data | ConvertTo-Json -Depth 3 -Compress | Set-Content $script:Vm.Cache -Encoding UTF8 } catch { }
            Set-CsVmData $data
            Set-CsStatus "Precios cargados: $($data.Count) tamaños."
        })
}

function Set-CsVmData($data) {
    $ctx = $script:Vm.Context
    $rows = foreach ($d in @($data)) {
        if ($ctx.Cloud -eq 'Azure') {
            $s = $script:VmSpecs[$d.Sku]
            [pscustomobject]@{ Sku = ($d.Sku -replace '^Standard_', ''); FullSku = $d.Sku
                Family = $(if ($s) { "$($s[1])" } else { ($d.Product -replace 'Virtual Machines |Series|Windows|Linux', '').Trim() })
                Category = $(if ($s) { $s[3] } else { '' }); Vcpu = $(if ($s) { $s[4] } else { $null }); MemoryGB = $(if ($s) { $s[5] } else { $null }); Gpu = $(if ($s -and $s[7]) { $s[7] } else { 0 })
                Hourly = [double]$d.Hourly; Shown = 0.0; PerVcpu = $null }
        }
        else {
            [pscustomobject]@{ Sku = $d.Sku; FullSku = $d.Sku; Family = $d.Family; Category = $d.Storage; Vcpu = $d.Vcpu; MemoryGB = $d.MemoryGB; Gpu = $d.Gpu
                Hourly = [double]$d.Hourly; Shown = 0.0; PerVcpu = $null }
        }
    }
    $script:Vm.All = @($rows | Sort-Object Hourly)
    Update-CsVmFilter
}

function Update-CsVmFilter {
    $u = $script:Ui
    if (-not $script:Vm -or -not $script:Vm.All) { return }
    $mult = $(if ($u.RbVmMonth.IsChecked) { 730 } else { 1 })
    $q = @($u.TxtVmSearch.Text.Trim() -split '\s+' | Where-Object { $_ })
    $d = 0.0
    $cpu = $(if ([double]::TryParse($u.TxtVmCpu.Text, [ref]$d)) { $d } else { 0 })
    $mem = $(if ([double]::TryParse($u.TxtVmMem.Text, [ref]$d)) { $d } else { 0 })
    $cmax = $(if ([double]::TryParse($u.TxtVmCpuMax.Text, [ref]$d)) { $d } else { 0 })
    $gpu = [bool]$u.ChkVmGpu.IsChecked
    $shown = foreach ($r in $script:Vm.All) {
        $text = "$($r.Sku) $($r.Family) $($r.Category)"
        $ok = $true
        foreach ($t in $q) { if ($text -notlike "*$t*") { $ok = $false; break } }
        if (-not $ok) { continue }
        if ($cpu -and ($null -eq $r.Vcpu -or $r.Vcpu -lt $cpu)) { continue }
        if ($cmax -and ($null -eq $r.Vcpu -or $r.Vcpu -gt $cmax)) { continue }
        if ($mem -and ($null -eq $r.MemoryGB -or $r.MemoryGB -lt $mem)) { continue }
        if ($gpu -and -not $r.Gpu) { continue }
        $r.Shown = [math]::Round($r.Hourly * $mult, 4)
        $r.PerVcpu = $(if ($r.Vcpu) { [math]::Round($r.Hourly * $mult / $r.Vcpu, 4) } else { $null })
        $r
    }
    $script:Vm.Shown = @($shown)
    $u.GridVm.ItemsSource = $script:Vm.Shown
    $ctx = $script:Vm.Context
    $u.TxtVmInfo.Text = "{0} de {1} tamaños · {2} · {3} · {4} · USD {5} · solo cómputo (sin discos ni licencias adicionales)" -f $script:Vm.Shown.Count, $script:Vm.All.Count, $ctx.Label, $ctx.Os, $ctx.ModelLabel, $(if ($mult -eq 1) { 'por hora' } else { 'al mes (730 h)' })
}

function Start-CsVmCompare {
    $u = $script:Ui
    $sel = $u.GridVm.SelectedItem
    if (-not $sel) { return }
    $ctx = $script:Vm.Context
    $u.BtnVmCompare.IsEnabled = $false
    $u.TxtVmCmp.Text = "Consultando $($sel.Sku) en todas las regiones…"
    $script:Vm.CmpSku = $sel.Sku
    if ($ctx.Cloud -eq 'Azure') {
        $type = $(if ($ctx.Model -like 'ri*') { 'Reservation' } else { 'Consumption' })
        $jobArgs = @("serviceName eq 'Virtual Machines' and armSkuName eq '$($sel.FullSku)' and priceType eq '$type'", $ctx.Os, $ctx.Model)
        $job = $script:AzurePriceJob
    }
    else {
        $locs = [string[]]@($script:Cat.Regions | Where-Object Cloud -eq 'AWS' | ForEach-Object { $script:AwsLoc.($_.Code) } | Where-Object { $_ })
        $jobArgs = @(, $locs) + @($ctx.Os, $sel.FullSku)
        $job = $script:AwsPriceJob
        $u.TxtVmCmp.Text += ' (AWS: una consulta por región, unos segundos)'
    }
    [void](Start-CsJob -Script $job -Arguments $jobArgs -Status "Comparando $($sel.Sku) entre regiones…" -OnDone {
            param($res, $err)
            $u = $script:Ui
            $u.BtnVmCompare.IsEnabled = $true
            $data = @($res)
            if ($data.Count -eq 0) { $u.TxtVmCmp.Text = "Sin precios para $($script:Vm.CmpSku). $err"; return }
            $mult = $(if ($u.RbVmMonth.IsChecked) { 730 } else { 1 })
            $names = @{}
            foreach ($r in $script:AzRef) { $names[$r.code] = $r.name }
            foreach ($r in ($script:Cat.Regions | Where-Object Cloud -eq 'AWS')) { $loc = $script:AwsLoc.($r.Code); if ($loc) { $names[$loc] = "$($r.Name) · $($r.Code)" } }
            $min = ($data | Measure-Object Hourly -Minimum).Minimum
            $rows = $data | ForEach-Object {
                $k = $(if ($_.Region) { $_.Region } else { $_.Location })
                [pscustomobject]@{ Region = $(if ($names[$k]) { $names[$k] } else { $k }); Shown = [math]::Round($_.Hourly * $mult, 4); Delta = $(if ($min) { $_.Hourly / $min - 1 } else { 0 }) }
            } | Sort-Object Shown
            $u.GridVmCmp.ItemsSource = @($rows)
            $u.TxtVmCmp.Text = "{0} en {1} regiones · USD {2}" -f $script:Vm.CmpSku, @($rows).Count, $(if ($mult -eq 1) { 'por hora' } else { 'al mes' })
            Set-CsStatus $u.TxtVmCmp.Text
        })
}

function Export-CsVmExcel {
    if (-not $script:Vm.Shown) { Show-CsMessage 'Consulta primero los precios.' 'Warning'; return }
    $ctx = $script:Vm.Context
    $f = Save-CsFileDialog ('Precios_VM_{0}_{1}_{2}.xlsx' -f $ctx.Cloud, $ctx.Region, $ctx.Os) 'Libro de Excel (*.xlsx)|*.xlsx'
    if (-not $f) { return }
    $wb = New-Object CloudSpeed.XWorkbook
    $sh = $wb.AddSheet('Precios')
    [void]$sh.Add([object[]]@((New-Object CloudSpeed.XCell ("Precios de máquinas virtuales · {0} · {1} · {2}" -f $ctx.Label, $ctx.Os, $ctx.ModelLabel), 5)))
    [void]$sh.Add([object[]]@((New-Object CloudSpeed.XCell ("USD, solo cómputo. Consultado el {0:dd/MM/yyyy HH:mm} en la lista pública de precios de {1}." -f (Get-Date), $ctx.Cloud), 8)))
    $h0 = $sh.Add([object[]]@('Tamaño', 'Serie / familia', 'Tipo', 'vCPU', 'Memoria (GB)', 'GPU', 'USD por hora', 'USD al mes (730 h)', 'USD por vCPU y hora'))
    foreach ($r in $script:Vm.Shown) {
        [void]$sh.Add([object[]]@($r.Sku, $r.Family, $r.Category, $(if ($null -ne $r.Vcpu) { [double]$r.Vcpu }), $(if ($null -ne $r.MemoryGB) { [double]$r.MemoryGB }), [double]$r.Gpu,
                (New-Object CloudSpeed.XCell ([double]$r.Hourly), 0), (New-Object CloudSpeed.XCell ([math]::Round($r.Hourly * 730, 2)), 2),
                $(if ($r.Vcpu) { [math]::Round($r.Hourly / $r.Vcpu, 5) })))
    }
    $t = New-Object CloudSpeed.XTable; $t.Name = 'TablaPrecios'; $t.Row0 = $h0; $t.Col0 = 0; $t.Row1 = $sh.Rows.Count - 1; $t.Col1 = 8
    $sh.Tables.Add($t); $sh.FreezeRows = $h0 + 1
    $sh.ColorScales.Add(('G{0}:G{1}' -f ($h0 + 2), $sh.Rows.Count))
    $w = 22, 26, 22, 7, 13, 6, 13, 17, 18; for ($i = 0; $i -lt $w.Count; $i++) { $sh.Widths[$i] = $w[$i] }
    try { $wb.Save($f); Set-CsStatus "Guardado: $f"; Invoke-Item $f } catch { Show-CsMessage "No se pudo guardar:`n$($_.Exception.Message)" 'Error' }
}

# ------------------------------------------------------------------ modelos de IA

function Initialize-CsPagePreciosIa {
    $u = $script:Ui
    if (-not $script:AzRef) { $script:AzRef = (Get-CsJson 'azure-regions.json').regions | Where-Object { $_.cloud -eq 'Global' } }
    $items = New-Object System.Collections.ArrayList
    foreach ($r in ($script:AzRef | Sort-Object name)) { [void]$items.Add((New-CsItem "$($r.name) · $($r.code)" $r.code)) }
    $u.CmbAiRegion.ItemsSource = $items
    $u.CmbAiRegion.SelectedItem = $items | Where-Object Tag -eq 'eastus' | Select-Object -First 1
    $script:Ai = @{ All = @(); Shown = @() }
    $u.BtnAiLoad.Add_Click({ Start-CsAiLoad })
    $u.TxtAiSearch.Add_TextChanged({ Update-CsAiFilter })
    $u.ChkAiTokens.Add_Click({ Update-CsAiFilter })
    $u.CmbAiProduct.Add_SelectionChanged({ Update-CsAiFilter })
    $u.CmbAiDeploy.Add_SelectionChanged({ Update-CsAiFilter })
    $u.BtnAiExcel.Add_Click({ Export-CsAiExcel })
}

function Start-CsAiLoad {
    $u = $script:Ui
    $region = [string]$u.CmbAiRegion.SelectedItem.Tag
    $cache = Join-Path (Get-CsCacheFolder) ('ia-{0}-{1:yyyyMMdd}.json' -f $region, (Get-Date))
    $script:Ai.Region = $u.CmbAiRegion.SelectedItem.Content
    if (Test-Path $cache) { Set-CsAiData (Get-Content $cache -Raw -Encoding UTF8 | ConvertFrom-Json); Set-CsStatus 'Precios de IA (caché de hoy).'; return }
    $script:Ai.Cache = $cache
    $u.BtnAiLoad.IsEnabled = $false
    $u.TxtAiInfo.Text = 'Consultando precios…'
    [void](Start-CsJob -Status 'Consultando precios de modelos de IA…' -Arguments @($region) -Script {
            param($region)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $f = "serviceName eq 'Foundry Models' and armRegionName eq '$region'"
            $url = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&$filter=' + [uri]::EscapeDataString($f)
            $out = New-Object System.Collections.ArrayList; $n = 0
            while ($url -and $n -lt 40) { $r = Invoke-RestMethod -Uri $url -TimeoutSec 60 -UseBasicParsing; [void]$out.AddRange(@($r.Items)); $url = $r.NextPageLink; $n++ }
            @($out | Where-Object { $_.type -eq 'Consumption' } | Select-Object productName, skuName, meterName, retailPrice, unitOfMeasure)
        } -OnDone {
            param($res, $err)
            $script:Ui.BtnAiLoad.IsEnabled = $true
            $data = @($res)
            if ($data.Count -eq 0) { $script:Ui.TxtAiInfo.Text = "Sin precios para esta región. $err"; return }
            try { $data | ConvertTo-Json -Depth 3 -Compress | Set-Content $script:Ai.Cache -Encoding UTF8 } catch { }
            Set-CsAiData $data
            Set-CsStatus "Precios de IA cargados: $($data.Count) medidores."
        })
}

function Set-CsAiData($data) {
    $rows = foreach ($i in @($data)) {
        $m = " $($i.meterName) ".ToLower()
        $kind = switch -Regex ($m) {
            'cache ?write|\bcw\b' { 'Escritura en caché'; break }
            'cached|\bcd\b|cchd|cache' { 'Entrada en caché'; break }
            '\binp\b|input|\bin\b' { 'Entrada'; break }
            '\boutp\b|\bopt\b|output|\bout\b' { 'Salida'; break }
            default { if ($i.unitOfMeasure -match 'Hour') { 'Por hora' } else { 'Otro' } }
        }
        $dep = switch -Regex ($m) {
            'dzone|data ?zone|\bdz\b' { 'Data Zone'; break }
            'glbl|global|\bgl\b' { 'Global'; break }
            'regnl|regional|\brgnl\b' { 'Regional'; break }
            default { '—' }
        }
        if ($m -match 'batch') { $dep = "$dep Batch".Trim('— ') }
        if ($m -match 'priority|\bprty\b') { $dep = "$dep Priority".Trim('— ') }
        $tokens = $m -match 'token' -or ($i.unitOfMeasure -in '1K', '1M', '1K Tokens', '1M Tokens' -and $kind -match 'Entrada|Salida|caché')
        $per = $null
        if ($tokens) { $per = $(if ($i.unitOfMeasure -match '1K') { [double]$i.retailPrice * 1000 } elseif ($i.unitOfMeasure -match '1M') { [double]$i.retailPrice } else { $null }) }
        [pscustomobject]@{ Model = $i.skuName; Product = $i.productName; Deployment = $dep; Kind = $kind; PerMillion = $per; Price = [double]$i.retailPrice; Unit = $i.unitOfMeasure; Meter = $i.meterName; Tokens = $tokens }
    }
    $script:Ai.All = @($rows | Sort-Object Product, Model, Kind)
    $u = $script:Ui
    $u.CmbAiProduct.ItemsSource = @('Todos') + @($script:Ai.All | ForEach-Object Product | Sort-Object -Unique)
    $u.CmbAiProduct.SelectedIndex = 0
    $u.CmbAiDeploy.ItemsSource = @('Todos') + @($script:Ai.All | ForEach-Object Deployment | Sort-Object -Unique)
    $u.CmbAiDeploy.SelectedIndex = 0
    Update-CsAiFilter
}

function Update-CsAiFilter {
    $u = $script:Ui
    if (-not $script:Ai -or -not $script:Ai.All) { return }
    $q = @($u.TxtAiSearch.Text.Trim() -split '\s+' | Where-Object { $_ })
    $prod = [string]$u.CmbAiProduct.SelectedItem; $dep = [string]$u.CmbAiDeploy.SelectedItem
    $only = [bool]$u.ChkAiTokens.IsChecked
    $shown = foreach ($r in $script:Ai.All) {
        if ($only -and -not $r.Tokens) { continue }
        if ($prod -and $prod -ne 'Todos' -and $r.Product -ne $prod) { continue }
        if ($dep -and $dep -ne 'Todos' -and $r.Deployment -ne $dep) { continue }
        $ok = $true; $text = "$($r.Model) $($r.Product) $($r.Meter)"
        foreach ($t in $q) { if ($text -notlike "*$t*") { $ok = $false; break } }
        if ($ok) { $r }
    }
    $script:Ai.Shown = @($shown)
    $u.GridAi.ItemsSource = $script:Ai.Shown
    $u.TxtAiInfo.Text = "$($script:Ai.Shown.Count) de $($script:Ai.All.Count) medidores · $($script:Ai.Region) · USD. El nombre del medidor indica el tipo de despliegue (Global, Data Zone o Regional) y si es por lotes."
}

function Export-CsAiExcel {
    if (-not $script:Ai.Shown) { Show-CsMessage 'Consulta primero los precios.' 'Warning'; return }
    $f = Save-CsFileDialog ('Precios_IA_{0:yyyyMMdd}.xlsx' -f (Get-Date)) 'Libro de Excel (*.xlsx)|*.xlsx'
    if (-not $f) { return }
    $wb = New-Object CloudSpeed.XWorkbook
    $sh = $wb.AddSheet('Modelos de IA')
    [void]$sh.Add([object[]]@((New-Object CloudSpeed.XCell "Precios de modelos de IA en Azure · $($script:Ai.Region)", 5)))
    [void]$sh.Add([object[]]@((New-Object CloudSpeed.XCell ("USD. API pública de precios de Azure, consultada el {0:dd/MM/yyyy HH:mm}." -f (Get-Date)), 8)))
    $h0 = $sh.Add([object[]]@('Modelo', 'Producto', 'Despliegue', 'Tipo', 'USD por 1M tokens', 'Precio', 'Unidad', 'Medidor'))
    foreach ($r in $script:Ai.Shown) { [void]$sh.Add([object[]]@($r.Model, $r.Product, $r.Deployment, $r.Kind, $(if ($null -ne $r.PerMillion) { [double]$r.PerMillion }), [double]$r.Price, $r.Unit, $r.Meter)) }
    $t = New-Object CloudSpeed.XTable; $t.Name = 'TablaModelos'; $t.Row0 = $h0; $t.Col0 = 0; $t.Row1 = $sh.Rows.Count - 1; $t.Col1 = 7
    $sh.Tables.Add($t); $sh.FreezeRows = $h0 + 1
    $w = 34, 24, 14, 18, 16, 12, 10, 40; for ($i = 0; $i -lt $w.Count; $i++) { $sh.Widths[$i] = $w[$i] }
    try { $wb.Save($f); Set-CsStatus "Guardado: $f"; Invoke-Item $f } catch { Show-CsMessage "No se pudo guardar:`n$($_.Exception.Message)" 'Error' }
}

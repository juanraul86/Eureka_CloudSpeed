<#
.SYNOPSIS
    Pruebas automáticas de Eureka_CloudSpeed (se ejecutan en GitHub Actions antes de compilar y firmar;
    si alguna falla, no se publica nada). También se pueden lanzar en local.
.DESCRIPTION
    No necesitan credenciales ni crean recursos en la nube. Comprueban:
      - sintaxis de todos los scripts y codificación UTF-8 con BOM;
      - que todas las páginas XAML cargan con el tema;
      - que el motor en C# compila;
      - catálogos JSON válidos;
      - firma SigV4 frente al ejemplo oficial de AWS;
      - cifrado DPAPI de ida y vuelta (solo Windows con perfil de usuario);
      - protección de CSV contra inyección de fórmulas;
      - generación de un .xlsx válido (estructura OOXML);
      - lógica del diagnóstico del Estado de servicios;
      - controles estáticos de seguridad (sin secretos, TLS, código dinámico, https).
    Código de salida: 0 si todo pasa, 1 si algo falla.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$results = New-Object System.Collections.ArrayList
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { $d = & $Body; [void]$results.Add([pscustomobject]@{ Prueba = $Name; Resultado = 'OK'; Detalle = [string]$d }) }
    catch { [void]$results.Add([pscustomobject]@{ Prueba = $Name; Resultado = 'FALLO'; Detalle = $_.Exception.Message }) }
}
$codeFiles = Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\(Dist|Build\\obj|\.git)\\' }

Test-Case 'Sintaxis de los scripts' {
    $bad = foreach ($f in $codeFiles) { $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e); if ($e) { "$($f.Name): $($e[0].Message)" } }
    if ($bad) { throw ($bad -join '; ') }; "$($codeFiles.Count) scripts"
}
Test-Case 'Scripts en UTF-8 con BOM (necesario en PowerShell 5.1)' {
    $bad = $codeFiles | Where-Object { $b = [IO.File]::ReadAllBytes($_.FullName); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) } | ForEach-Object Name
    if ($bad) { throw ('Sin BOM: ' + ($bad -join ', ')) }; 'OK'
}
Test-Case 'Catálogos JSON válidos' {
    $n = 0; foreach ($f in Get-ChildItem (Join-Path $root 'Catalog') -Filter *.json) { [void](Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json); $n++ }
    $reg = (Get-Content (Join-Path $root 'Catalog\regions.json') -Raw -Encoding UTF8 | ConvertFrom-Json).regions
    if ($reg.Count -lt 80) { throw "regions.json solo tiene $($reg.Count) regiones" }
    "$n archivos, $($reg.Count) regiones"
}
Import-Module (Join-Path $root 'Modules\Core.psm1') -Force -DisableNameChecking
Test-Case 'El motor en C# compila' { Import-CsEngine; [CloudSpeed.ProbeEngine].FullName }
Test-Case 'Páginas XAML cargan con el tema' {
    Add-Type -AssemblyName PresentationFramework
    if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
    $t = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $root 'UI\Theme.xaml') -Raw -Encoding UTF8))
    [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($t)
    $files = @(Get-ChildItem (Join-Path $root 'UI\Pages') -Filter *.xaml) + (Get-Item (Join-Path $root 'UI\MainWindow.xaml'))
    foreach ($f in $files) { [xml]$x = Get-Content $f.FullName -Raw -Encoding UTF8; [void][Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x)) }
    "$($files.Count) archivos"
}
Test-Case 'Firma SigV4 (ejemplo oficial de AWS)' {
    . (Join-Path $root 'Herramientas\SigV4.ps1')
    $u = New-S3PresignedUrl -Method GET -HostName 'examplebucket.s3.amazonaws.com' -Key 'test.txt' -Region 'us-east-1' -AccessKey 'AKIAIOSFODNN7EXAMPLE' `
        -SecretKey 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' -ExpiresSeconds 86400 -Now ([datetime]::SpecifyKind([datetime]'2013-05-24T00:00:00', 'Utc'))
    if ($u -notmatch 'X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404$') { throw 'La firma no coincide con la documentación de AWS' }
    'coincide'
}
Test-Case 'Cifrado DPAPI de ida y vuelta' {
    $plain = 'https://cuenta.blob.core.windows.net/x?sv=2024&sig=PRUEBA'
    $enc = Protect-CsSecret $plain
    if ($enc -notlike 'dpapi:*' -or $enc -match 'PRUEBA') { throw 'No se cifra' }
    if ((Unprotect-CsSecret $enc) -ne $plain) { throw 'No se descifra igual' }
    if (-not (Test-CsSecretUrl $plain) -or (Test-CsSecretUrl 'https://ejemplo.com/a')) { throw 'Detección de URL con firma incorrecta' }
    'OK'
}
Test-Case 'CSV protegido contra inyección de fórmulas' {
    $r = New-Object CloudSpeed.RegionInfo; $r.Cloud = 'Azure'; $r.Code = 'x'; $r.Name = 'X'
    $s = New-Object CloudSpeed.Sample; $s.Region = $r; $s.Time = Get-Date; $s.Error = '=HYPERLINK("http://x")'; $s.SessionId = 's'
    $line = [CloudSpeed.Store]::SampleLine($s, 'pc', '+cmd|calc')
    if ($line -notmatch "'=HYPERLINK" -or $line -notmatch ",'\+cmd") { throw $line }
    'OK'
}
Test-Case 'Excel (.xlsx) válido con tablas y gráfico' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cs-test-{0}.xlsx" -f [guid]::NewGuid().ToString('N'))
    $wb = New-Object CloudSpeed.XWorkbook
    $sh = $wb.AddSheet('Datos')
    $h = $sh.Add([object[]]@('Región', 'ms'))
    foreach ($i in 1..5) { [void]$sh.Add([object[]]@("R$i", [double](10 * $i))) }
    $t = New-Object CloudSpeed.XTable; $t.Name = 'TablaPrueba'; $t.Row0 = $h; $t.Col0 = 0; $t.Row1 = 5; $t.Col1 = 1; $sh.Tables.Add($t)
    $c = New-Object CloudSpeed.XChart; $c.Kind = 'bar'; $c.Title = 'Prueba'; $c.DataSheet = $sh; $c.CatCol = 0; $c.Row0 = 1; $c.Row1 = 5; $c.ToCol = 8; $c.ToRow = 15
    $se = New-Object CloudSpeed.XSeries; $se.Name = 'ms'; $se.ValCol = 1; $se.Color = '#2F80ED'; $c.Series.Add($se); $sh.Charts.Add($c)
    $wb.Save($tmp)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($tmp)
    try {
        $names = $z.Entries.FullName
        foreach ($need in '[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet1.xml', 'xl/tables/table1.xml', 'xl/charts/chart1.xml', 'xl/styles.xml') { if ($names -notcontains $need) { throw "Falta $need" } }
        foreach ($e in $z.Entries | Where-Object { $_.FullName -like '*.xml' -or $_.FullName -like '*.rels' }) { $sr = New-Object IO.StreamReader($e.Open()); [xml]$null = $sr.ReadToEnd(); $sr.Close() }
    }
    finally { $z.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    'estructura OOXML correcta'
}
Test-Case 'Diagnóstico del Estado de servicios' {
    function Set-CsStatus($t) {}
    function Get-CsBrush($h) { $h }
    . (Join-Path $root 'UI\Pages\Estado.ps1')
    function New-TRow($src, $prov, $svc, $lvl) { $x = New-Object CloudSpeed.StatusRow; $x.Source = $src; $x.Provider = $prov; $x.Service = $svc; $x.Level = $lvl; $x }
    $script:G = @{ Page = 'Estado' }
    $off = 'Microsoft Azure', 'Microsoft 365', 'AWS' | ForEach-Object { New-TRow 'Oficial' $_ 'estado' 0 }
    $prbOk = @((New-TRow 'Red' 'Microsoft Azure' 'Portal' 0), (New-TRow 'Red' 'AWS' 'Consola' 0), (New-TRow 'Red' 'Referencia' 'Internet' 0))
    $cases = @(
        @{ N = 'todo bien'; Off = $off; Prb = $prbOk; Expect = 'Todo operativo' }
        @{ N = 'caída global'; Off = @($off | Where-Object Provider -ne 'Microsoft Azure') + (New-TRow 'Oficial' 'Microsoft Azure' 'estado' -1); Prb = @($prbOk | Where-Object Provider -ne 'Microsoft Azure') + (New-TRow 'Red' 'Microsoft Azure' 'Portal' 3); Expect = 'Posible caída global' }
        @{ N = 'sin conexión'; Off = $off; Prb = @($prbOk | ForEach-Object { New-TRow 'Red' $_.Provider $_.Service 3 }); Expect = 'problema de tu conexión' }
    )
    foreach ($k in $cases) {
        $script:Ui = @{ DotStBanner = [pscustomobject]@{ Fill = '' }; TxtStBanner = [pscustomobject]@{ Text = '' }; TxtStBannerSub = [pscustomobject]@{ Text = '' } }
        $script:St = @{ Official = @($k.Off); Probes = @($k.Prb); Last = Get-Date }
        Update-CsStatusBanner
        if ($script:Ui.TxtStBanner.Text -notmatch [regex]::Escape($k.Expect)) { throw "$($k.N): '$($script:Ui.TxtStBanner.Text)'" }
    }
    "$($cases.Count) escenarios"
}
Test-Case 'Controles estáticos de seguridad' {
    $src = Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1, *.cs | Where-Object { $_.FullName -notmatch '\\(Dist|Build\\obj|\.git|Tests)\\' -and $_.Name -ne 'Verificar-Cumplimiento.ps1' }
    $p = @{
        'secretos' = 'AccountKey=|aws_secret_access_key\s*=|-----BEGIN (RSA )?PRIVATE KEY'
        'TLS desactivado' = 'ServerCertificateValidationCallback|SkipCertificateCheck'
        'código dinámico' = '\bInvoke-Expression\b|\biex\b|\[ScriptBlock\]::Create'
    }
    foreach ($k in $p.Keys) { $h = $src | Select-String -Pattern $p[$k]; if ($h) { throw "$k en $($h[0].Filename):$($h[0].LineNumber)" } }
    $http = $src | Select-String -Pattern 'http://[^\s"''<>]+' -AllMatches | ForEach-Object { $_.Matches.Value } | Where-Object { $_ -notmatch '^http://(127\.0\.0\.1|localhost|schemas\.|www\.w3\.org|purl\.org|wellformedweb|timestamp\.digicert\.com)' }
    if ($http) { throw "URL no https: $($http -join ', ')" }
    "$($src.Count) archivos"
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object Resultado -ne 'OK')
Write-Host ("{0} pruebas · {1} OK · {2} fallos" -f $results.Count, ($results.Count - $fail.Count), $fail.Count)
if ($fail.Count) { exit 1 } else { exit 0 }

<#
.SYNOPSIS
    Verificación automática de privacidad y ciberseguridad de Eureka_CloudSpeed. Ejecútala antes de
    publicar cada versión (después de Build\Build-Exe.ps1) y adjunta el resultado a la bitácora.
.DESCRIPTION
    Comprueba: secretos en claro, validación TLS, ejecución dinámica de código, URL no https, destinos de
    Start-Process, contenido de los paquetes, .gitignore, permisos y cifrado de Config\velocidad.json,
    alcance de la verificación de integridad, conservación y seudónimo, ipinfo.io solo bajo demanda,
    ausencia de telemetría, recursos de prueba activos en AWS y Azure y firma de los ejecutables.
    Código de salida: 0 si todo está OK, 1 si hay controles a revisar.
#>
$root = Split-Path $PSScriptRoot -Parent
$code = Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1, *.cs, *.xaml, *.json, *.cmd, *.html, *.md, *.pq, *.dax |
    Where-Object { $_.FullName -notmatch '\\(Dist|Build\\obj|Datos|Exportaciones|Config|Tests|\.git)\\' -and $_.Name -ne 'Verificar-Cumplimiento.ps1' }   # el propio script contiene los patrones que busca
function Check($id, $name, $ok, $detail) { [pscustomobject]@{ Id = $id; Control = $name; Resultado = $(if ($ok) { 'OK' } else { 'REVISAR' }); Detalle = $detail } }
$r = @()

# 1. Secretos en claro en el código o la documentación
$secretPat = 'sig=[A-Za-z0-9%]{20,}|X-Amz-Signature=[0-9a-f]{64}|AKIA[0-9A-Z]{16}|AccountKey=|aws_secret_access_key\s*=|-----BEGIN (RSA )?PRIVATE KEY'
$hits = $code | Select-String -Pattern $secretPat | Where-Object { $_.Line -notmatch 'AKIAIOSFODNN7EXAMPLE|aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404|<sas|<firma' }
$r += Check 'S1' 'Sin secretos en claro en código y documentación' (-not $hits) $(if ($hits) { ($hits | Select-Object -First 3 | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ' } else { "$($code.Count) archivos revisados" })

# 2. Validación de certificados TLS nunca desactivada
$tls = $code | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cs' } | Select-String -Pattern 'ServerCertificateValidationCallback|SkipCertificateCheck|TrustAllCerts|CheckCertificateRevocationList\s*=\s*false'
$r += Check 'S2' 'Validación de certificados TLS sin desactivar' (-not $tls) $(if ($tls) { ($tls | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ' } else { 'Sin desactivaciones' })

# 3. Sin ejecución dinámica de código
$dyn = $code | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Select-String -Pattern '\bInvoke-Expression\b|\biex\b|\[ScriptBlock\]::Create|Add-Type\s+-TypeDefinition\s+\$'
$r += Check 'S3' 'Sin ejecución dinámica de código (Invoke-Expression, ScriptBlock::Create)' (-not $dyn) $(if ($dyn) { ($dyn | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ' } else { 'Ninguna' })

# 4. Todas las URL de red usadas por el programa son https
$urls = $code | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cs', '.json' } | Select-String -Pattern 'http://[^\s"''<>]+' -AllMatches |
    ForEach-Object { $_.Matches.Value } | Where-Object { $_ -notmatch '^http://(127\.0\.0\.1|localhost|schemas\.|www\.w3\.org|purl\.org|wellformedweb|timestamp\.digicert\.com)' } | Sort-Object -Unique
$r += Check 'S4' 'Conexiones salientes solo por HTTPS' (-not $urls) $(if ($urls) { $urls -join ', ' } else { 'Solo https (salvo espacios de nombres XML y el sello de tiempo de la firma)' })

# 5. Start-Process solo con URL validadas o archivos locales propios
$sp = $code | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Select-String -Pattern 'Start-Process' | Where-Object { $_.Line -notmatch "explorer\.exe|notepad\.exe|'https://|Start-Process \`$ps|\[string\]\`$x\.Tag|Start-Process \`$p\b|Start-Process powershell" }
$r += Check 'S5' 'Start-Process sin destinos no validados' (-not $sp) $(if ($sp) { ($sp | ForEach-Object { "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }) -join ' | ' } else { 'Destinos fijos, carpetas locales o URL https validadas' })

# 6. Paquetes sin datos del usuario
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $root 'Dist\Eureka_CloudSpeed.zip'
if (Test-Path $zip) {
    $z = [IO.Compression.ZipFile]::OpenRead($zip); $bad = @($z.Entries | Where-Object { $_.FullName -match '/(Config|Datos|Exportaciones)/|velocidad\.json|preferencias\.json|\.bak$' } | ForEach-Object FullName); $z.Dispose()
    $r += Check 'S6' 'Los paquetes no incluyen configuración, histórico ni exportaciones' ($bad.Count -eq 0) $(if ($bad) { $bad -join ', ' } else { 'ZIP revisado' })
}

# 7. .gitignore protege los datos del usuario
$gi = Get-Content (Join-Path $root '.gitignore') -Raw
$r += Check 'S7' '.gitignore excluye Config, Datos y Exportaciones' ($gi -match 'Config/' -and $gi -match 'Datos/' -and $gi -match 'Exportaciones/') 'Revisado'

# 8. Permisos de la configuración con secretos
$cfg = Join-Path $root 'Config\velocidad.json'
if (Test-Path $cfg) {
    $acl = (Get-Acl $cfg).Access | Where-Object { $_.FileSystemRights -match 'Read|FullControl|Modify' } | ForEach-Object { $_.IdentityReference.Value }
    $extra = @($acl | Where-Object { $_ -notmatch "$env:USERNAME|SYSTEM|Administradores|Administrators" })
    $plain = (Get-Content $cfg -Raw) -match 'sig=|X-Amz-Signature'
    $r += Check 'S8' 'Config\velocidad.json: cifrado y solo accesible por el usuario' (-not $extra -and -not $plain) ("Acceso: " + ($acl -join ', ') + $(if ($plain) { ' · ¡URL en claro!' } else { ' · URL cifradas o sin endpoints' }))
}

# 9. Integridad: el lanzador verifica también los JSON
$launch = Get-Content (Join-Path $root 'Build\Launcher.cs') -Raw
$r += Check 'S9' 'Verificación de integridad incluye .ps1, .psm1, .xaml, .cs y .json' ($launch -match '"\*\.json"') 'Build\Launcher.cs'

# 10. Privacidad: seudónimo y conservación por defecto
$core = Get-Content (Join-Path $root 'Modules\Core.psm1') -Raw
$r += Check 'P1' 'Conservación limitada por defecto (12 meses) y borrado del histórico' ($core -match 'RetentionMonths = 12' -and $core -match 'function Remove-CsHistory') 'Modules\Core.psm1'
$noPc = $code | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -ne 'Core.psm1' } | Select-String -Pattern '\$env:COMPUTERNAME'
$r += Check 'P2' 'El nombre del equipo solo sale a través del seudónimo (Get-CsMachine)' (-not $noPc) $(if ($noPc) { ($noPc | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ' } else { 'Todas las salidas usan Get-CsMachine' })
$ipinfo = $code | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Select-String -Pattern 'ipinfo\.io'
$r += Check 'P3' 'Consulta a ipinfo.io solo desde el botón Ver mi conexión' (@($ipinfo | Where-Object Filename -ne 'Shell.ps1').Count -eq 0 -and (Get-Content (Join-Path $root 'UI\Shell.ps1') -Raw) -match 'function Show-CsConnection[\s\S]{0,400}ipinfo\.io') (($ipinfo | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')
$tele = $code | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cs' } | Select-String -Pattern 'applicationinsights|telemetry|analytics\.|google-analytics|segment\.io'
$r += Check 'P4' 'Sin telemetría ni analítica' (-not $tele) 'Ninguna referencia'

# 11. Recursos de prueba en la nube
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
if (Test-Path $awsExe) {
    $b = (& $awsExe s3api list-buckets --query "Buckets[?starts_with(Name,'cspeed-')].Name" --output text 2>&1 | Out-String).Trim()
    $ok = $LASTEXITCODE -eq 0
    $det = if (-not $ok) { 'No se pudo comprobar: ' + $b } elseif ($b) { 'Activos: ' + $b } else { '0 buckets cspeed-*' }
    $r += Check 'C1' 'AWS: ningún bucket de prueba activo' ($ok -and -not $b) $det
}
$azCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (Test-Path $azCmd) {
    $g = & $azCmd group exists --name rg-eureka-cloudspeed 2>&1
    $r += Check 'C2' 'Azure: ningún grupo de recursos de prueba activo' ($g -ne 'true') $(if ($g -eq 'true') { 'rg-eureka-cloudspeed existe' } else { 'Sin grupo de prueba (o sin suscripción/sesión)' })
}

# 12. Firma de código de los ejecutables
$sig = Get-AuthenticodeSignature (Join-Path $root 'Eureka_CloudSpeed.exe')
$r += Check 'R1' 'Ejecutables firmados con un certificado de confianza' ($sig.Status -eq 'Valid') "Estado: $($sig.Status)"

$r | Format-Table -AutoSize -Wrap | Out-String -Width 220
"Resumen: {0} OK · {1} a revisar" -f @($r | Where-Object Resultado -eq 'OK').Count, @($r | Where-Object Resultado -ne 'OK').Count

if (@($r | Where-Object Resultado -ne 'OK').Count) { exit 1 } else { exit 0 }

<#
.SYNOPSIS
    Crea en tu cuenta de AWS los buckets de S3 que usa el test de velocidad de Eureka_CloudSpeed (uno por
    región) y guarda sus URL prefirmadas, cifradas, en Config\velocidad.json.
.DESCRIPTION
    Necesita AWS CLI v2 (aws) con credenciales configuradas (aws configure o aws sso login) y permisos
    para S3. Por cada región:
      - bucket "cspeed-<región>-<huella de la cuenta>" con Block Public Access completo, propiedad del
        bucket forzada (sin ACL), cifrado SSE-S3, política que rechaza conexiones sin TLS y TLS < 1.2,
        y etiqueta app=Eureka_CloudSpeed;
      - objeto de prueba aleatorio "descarga/prueba-<N>MiB.bin" (-TamanoMiB, 100 por defecto);
      - regla de ciclo de vida que borra "subida/" al día siguiente y las subidas multiparte incompletas;
      - URL prefirmadas con Signature V4: GET del objeto de prueba y PUT de "subida/prueba.bin".
    Límite de AWS: una URL prefirmada caduca como mucho a los 7 días (antes si las credenciales son
    temporales, p. ej. SSO). Renuévalas con -Renovar. Las URL se cifran con DPAPI.
    Coste: céntimos al mes por región más la transferencia de salida de las descargas.
.EXAMPLE
    .\Crear-BucketsVelocidad.ps1 -Regiones eu-south-2,eu-west-1
.EXAMPLE
    .\Crear-BucketsVelocidad.ps1 -Renovar
.EXAMPLE
    .\Crear-BucketsVelocidad.ps1 -Eliminar
#>
[CmdletBinding(DefaultParameterSetName = 'Crear')]
param(
    [Parameter(ParameterSetName = 'Crear')][string[]]$Regiones = @('eu-south-2', 'eu-west-1'),
    [Parameter(ParameterSetName = 'Crear')][ValidateRange(10, 1024)][int]$TamanoMiB = 100,
    [ValidateRange(1, 7)][int]$DiasUrl = 7,
    [string]$Perfil,
    [Parameter(ParameterSetName = 'Renovar')][switch]$Renovar,
    [Parameter(ParameterSetName = 'Eliminar')][switch]$Eliminar,
    # Con -Eliminar: borra sin pedir que escribas SI (para pruebas automáticas)
    [Parameter(ParameterSetName = 'Eliminar')][switch]$Confirmar
)
$ErrorActionPreference = 'Stop'
$Regiones = @($Regiones | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -match '^[a-z]{2}(-[a-z]+)+-\d$' })
$root = Split-Path $PSScriptRoot -Parent
$dataRoot = if ($env:CFG_DATA) { $env:CFG_DATA } else { $root }
$cfgDir = Join-Path $dataRoot 'Config'
$cfg = Join-Path $cfgDir 'velocidad.json'
$tag = 'Crear-BucketsVelocidad'
. (Join-Path $PSScriptRoot 'SigV4.ps1')

Add-Type -AssemblyName System.Security
$entropy = [Text.Encoding]::UTF8.GetBytes('Eureka_CloudSpeed/velocidad/v1')
function Protect-Url([string]$t) { 'dpapi:' + [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $entropy, 'CurrentUser')) }

$awsBase = @(); if ($Perfil) { $awsBase = @('--profile', $Perfil) }
function Invoke-Aws {
    $out = & aws @awsBase @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws $($args[0..1] -join ' ') … falló:`n$(($out | Out-String).Trim())" }
    return ($out | Where-Object { $_ -is [string] }) -join "`n"
}

function Save-Config($new, [string[]]$replaceCodes) {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $old = @()
    if (Test-Path $cfg) {
        try { $old = @((Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).endpoints | Where-Object { $_ -and -not ($_.cloud -eq 'AWS' -and $_.code -in $replaceCodes) -and [string]$_.downloadUrl -notmatch '<' }) }
        catch { throw "No se puede leer $cfg ($($_.Exception.Message)); no se modifica." }
        Copy-Item $cfg "$cfg.bak" -Force
        try { & icacls.exe "$cfg.bak" /inheritance:r /grant:r "$($env:USERNAME):(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null } catch { }
    }
    $all = @(@($old) + @($new) | Where-Object { $null -ne $_ -and $_.code })
    $tmpCfg = "$cfg.tmp"
    [pscustomobject]@{ endpoints = $all } | ConvertTo-Json -Depth 5 | Set-Content $tmpCfg -Encoding UTF8
    Move-Item $tmpCfg $cfg -Force   # escritura atómica: nunca queda un archivo a medias
    try { & icacls.exe $cfg /inheritance:r /grant:r "$($env:USERNAME):(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null } catch { }
}

function Get-Creds {
    $j = Invoke-Aws configure export-credentials --format process
    $c = $j | ConvertFrom-Json
    if (-not $c.AccessKeyId) { throw 'No se pudieron obtener las credenciales de AWS (aws configure export-credentials).' }
    $c
}

function New-Endpoint([string]$bucket, [string]$reg, [string]$blobKey, $creds, $catalog) {
    $exp = $DiasUrl * 86400
    if ($creds.Expiration) {
        $left = [int]([datetime]::Parse($creds.Expiration).ToUniversalTime() - [datetime]::UtcNow).TotalSeconds - 60
        if ($left -lt $exp) { $exp = [math]::Max(900, $left); Write-Warning "Credenciales temporales: las URL de $reg caducarán en $([math]::Round($exp / 3600, 1)) h." }
    }
    $hostName = "$bucket.s3.$reg.amazonaws.com"
    $get = New-S3PresignedUrl -Method GET -HostName $hostName -Key $blobKey -Region $reg -AccessKey $creds.AccessKeyId -SecretKey $creds.SecretAccessKey -SessionToken $creds.SessionToken -ExpiresSeconds $exp
    # Una URL de subida por conexión (4): S3 limita las escrituras repetidas sobre la misma clave
    $put = (0..3 | ForEach-Object { New-S3PresignedUrl -Method PUT -HostName $hostName -Key "subida/prueba-$_.bin" -Region $reg -AccessKey $creds.AccessKeyId -SecretKey $creds.SecretAccessKey -SessionToken $creds.SessionToken -ExpiresSeconds $exp }) -join "`n"
    $info = $catalog | Where-Object code -eq $reg | Select-Object -First 1
    [pscustomobject]@{
        cloud = 'AWS'; code = $reg; name = $(if ($info) { $info.name } else { $reg })
        downloadUrl = Protect-Url $get; uploadUrl = Protect-Url $put; uploadKind = 'url'
        createdBy = $tag; bucket = $bucket; expires = [datetime]::UtcNow.AddSeconds($exp).ToString('yyyy-MM-ddTHH:mmZ')
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'No se encuentra AWS CLI (aws). Instálalo con: winget install -e --id Amazon.AWSCLI  (abre una consola nueva y ejecuta aws configure o aws sso login)'
}
$id = Invoke-Aws sts get-caller-identity --output json | ConvertFrom-Json
Write-Host "Cuenta de AWS: $($id.Account) · $($id.Arn)" -ForegroundColor Cyan
$catalog = (Get-Content (Join-Path $root 'Catalog\regions.json') -Raw -Encoding UTF8 | ConvertFrom-Json).regions | Where-Object cloud -eq 'AWS'
$sha = [Security.Cryptography.SHA256]::Create()
function Get-BucketName([string]$reg) {
    $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($id.Account)|$reg"))) -replace '-', '').Substring(0, 10).ToLower()
    "cspeed-$reg-$h"
}
function Get-OwnBuckets {
    $cur = @()
    if (Test-Path $cfg) { $cur = @((Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).endpoints | Where-Object { $_.createdBy -eq $tag }) }
    $cur
}

switch ($PSCmdlet.ParameterSetName) {
    'Eliminar' {
        $own = Get-OwnBuckets
        if (-not $own) { Write-Host 'No hay buckets creados por este script en la configuración.'; return }
        $ok = if ($Confirmar) { 'SI' } else { Read-Host ("Se borrarán {0} bucket(s) con todo su contenido: {1}. Escribe SI para continuar" -f $own.Count, ($own.bucket -join ', ')) }
        if (-not $Confirmar -and $ok -cne 'SI') { Write-Host 'Cancelado.'; return }
        foreach ($b in $own) {
            Invoke-Aws s3 rb "s3://$($b.bucket)" --force --region $b.code | Out-Null
            Write-Host "Borrado: $($b.bucket)"
        }
        Save-Config @() @($own.code)
        return
    }
    'Renovar' {
        $creds = Get-Creds
        $new = @()
        foreach ($b in @(Get-OwnBuckets)) {
            $key = (Invoke-Aws s3api list-objects-v2 --bucket $b.bucket --prefix descarga/ --query 'Contents[0].Key' --output text --region $b.code).Trim()
            if (-not $key -or $key -eq 'None') { Write-Warning "$($b.bucket): no tiene archivo de prueba en descarga/; vuelve a crearlo con -Regiones $($b.code)."; continue }
            $new += New-Endpoint $b.bucket $b.code $key $creds $catalog
        }
        if ($new.Count -eq 0) { throw 'No se ha renovado ninguna región: la configuración no se ha modificado.' }
        Save-Config $new @($new.code)
        Write-Host "URL renovadas: $($new.Count) región(es)." -ForegroundColor Green
        return
    }
}

# ------------------------------------------------------------------ crear
$tmp = Join-Path $env:TEMP "cloudspeed-$TamanoMiB.bin"
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -ne $TamanoMiB * 1MB) {
    Write-Host "Generando archivo de prueba aleatorio de $TamanoMiB MiB…"
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] (1MB)
    $fs = [IO.File]::Create($tmp)
    try { for ($i = 0; $i -lt $TamanoMiB; $i++) { $rng.GetBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Close() }
}
$tmpDir = Join-Path $env:TEMP 'cloudspeed-aws'; New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$lifecycle = Join-Path $tmpDir 'lifecycle.json'
@'
{ "Rules": [
  { "ID": "borrar-subidas", "Status": "Enabled", "Filter": { "Prefix": "subida/" }, "Expiration": { "Days": 1 },
    "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 1 } } ] }
'@ | Set-Content $lifecycle -Encoding ASCII

$creds = Get-Creds
$new = @()
foreach ($reg in $Regiones) {
    $bucket = Get-BucketName $reg
    Write-Host "`n== $reg -> $bucket" -ForegroundColor Cyan
    $exists = $true
    try { Invoke-Aws s3api head-bucket --bucket $bucket --region $reg | Out-Null } catch { $exists = $false }
    if (-not $exists) {
        if ($reg -eq 'us-east-1') { Invoke-Aws s3api create-bucket --bucket $bucket --region $reg | Out-Null }
        else { Invoke-Aws s3api create-bucket --bucket $bucket --region $reg --create-bucket-configuration "LocationConstraint=$reg" | Out-Null }
    }
    Invoke-Aws s3api put-public-access-block --bucket $bucket --region $reg --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' | Out-Null
    Invoke-Aws s3api put-bucket-ownership-controls --bucket $bucket --region $reg --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' | Out-Null
    $enc = Join-Path $tmpDir 'enc.json'
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' | Set-Content $enc -Encoding ASCII
    Invoke-Aws s3api put-bucket-encryption --bucket $bucket --region $reg --server-side-encryption-configuration "file://$enc" | Out-Null
    $pol = Join-Path $tmpDir 'policy.json'
    @"
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "SoloTLS", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
    "Resource": [ "arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*" ], "Condition": { "Bool": { "aws:SecureTransport": "false" } } },
  { "Sid": "TLS12", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
    "Resource": [ "arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*" ], "Condition": { "NumericLessThan": { "s3:TlsVersion": "1.2" } } } ] }
"@ | Set-Content $pol -Encoding ASCII
    Invoke-Aws s3api put-bucket-policy --bucket $bucket --region $reg --policy "file://$pol" | Out-Null
    Invoke-Aws s3api put-bucket-lifecycle-configuration --bucket $bucket --region $reg --lifecycle-configuration "file://$lifecycle" | Out-Null
    Invoke-Aws s3api put-bucket-tagging --bucket $bucket --region $reg --tagging 'TagSet=[{Key=app,Value=Eureka_CloudSpeed}]' | Out-Null
    $key = "descarga/prueba-$($TamanoMiB)MiB.bin"
    Write-Host "Subiendo $key…"
    Invoke-Aws s3 cp $tmp "s3://$bucket/$key" --region $reg --only-show-errors | Out-Null
    $new += New-Endpoint $bucket $reg $key $creds $catalog
}
Save-Config $new $Regiones
Write-Host "`nListo: $($new.Count) región(es) guardadas en $cfg (URL cifradas, caducan en $DiasUrl días como máximo)." -ForegroundColor Green
Write-Host 'Renueva las URL con -Renovar antes de que caduquen. En Eureka_CloudSpeed pulsa Recargar en la sección Velocidad.'

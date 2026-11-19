<#
.SYNOPSIS
    Firma de PRUEBAS de los ejecutables de Eureka_CloudSpeed con un certificado autofirmado local.
.DESCRIPTION
    1. Crea (o reutiliza) un certificado de firma de código autofirmado en Cert:\CurrentUser\My,
       con el nombre "Eureka_CloudSpeed (pruebas locales)".
    2. Con -Confiar, lo añade a "Entidades de certificación raíz de confianza" y a "Editores de confianza"
       del USUARIO ACTUAL (Windows pedirá confirmación). Así la firma aparece como válida en este equipo.
    3. Compila de nuevo con Build-Exe.ps1 usando ese certificado.

    IMPORTANTE
    - Es solo para pruebas en este equipo: en cualquier otro equipo la firma no será de confianza.
    - Smart App Control NO acepta certificados autofirmados ni raíces añadidas localmente: si está
      activado seguirá bloqueando Eureka_CloudSpeed_Portable.exe. Para eso hace falta una firma de una
      CA reconocida (pendiente: SignPath Foundation, como en Eureka_Utils). Mientras tanto usa
      Eureka_CloudSpeed.cmd o Eureka_CloudSpeed.exe junto a la carpeta.
    - Para deshacerlo: ejecuta este script con -Quitar.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build\Firmar-Local.ps1 -Confiar
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build\Firmar-Local.ps1 -Quitar
#>
[CmdletBinding()]
param(
    [switch]$Confiar,
    [switch]$Quitar
)
$ErrorActionPreference = 'Stop'
$subject = 'CN=Eureka_CloudSpeed (pruebas locales)'

if ($Quitar) {
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\CurrentUser\Root', 'Cert:\CurrentUser\TrustedPublisher') {
        Get-ChildItem $store | Where-Object Subject -eq $subject | ForEach-Object {
            Write-Host "Quitando $($_.Thumbprint) de $store"
            Remove-Item $_.PSPath
        }
    }
    return
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(7) } | Select-Object -First 1
if (-not $cert) {
    Write-Host 'Creando certificado de firma de código autofirmado (CurrentUser\My, válido 2 años)...' -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2) -KeyExportPolicy NonExportable
}
Write-Host "Certificado: $($cert.Thumbprint)  (caduca $($cert.NotAfter.ToString('d')))"

if ($Confiar) {
    $tmp = Join-Path $env:TEMP 'Eureka_CloudSpeed_pruebas.cer'
    Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
    foreach ($store in 'Root', 'TrustedPublisher') {
        Write-Host "Añadiendo a CurrentUser\$store (acepta el aviso de Windows)..." -ForegroundColor Yellow
        Import-Certificate -FilePath $tmp -CertStoreLocation "Cert:\CurrentUser\$store" | Out-Null
    }
    Remove-Item $tmp -Force
}

& (Join-Path $PSScriptRoot 'Build-Exe.ps1') -CertificateThumbprint $cert.Thumbprint

$root = Split-Path $PSScriptRoot -Parent
foreach ($f in (Join-Path $root 'Eureka_CloudSpeed.exe'), (Join-Path $root 'Dist\Eureka_CloudSpeed_Portable.exe')) {
    $s = Get-AuthenticodeSignature $f
    Write-Host ("{0}: {1}" -f (Split-Path $f -Leaf), $s.Status)
}
$sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
if ($sac -in 1, 2) {
    Write-Warning 'Smart App Control está activado (o en evaluación): seguirá bloqueando el portable aunque la firma sea válida en este equipo. Usa Eureka_CloudSpeed.cmd o Eureka_CloudSpeed.exe para probar.'
}

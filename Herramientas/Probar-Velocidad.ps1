<#
.SYNOPSIS
    Prueba completa y SIN COSTES RESIDUALES del test de velocidad: crea el almacenamiento en Azure y/o AWS,
    mide latencia, descarga y subida, y SIEMPRE borra lo creado al terminar (aunque falle o se interrumpa).
.DESCRIPTION
    1. Crea los recursos con Crear-CuentasVelocidad.ps1 (Azure) o Crear-BucketsVelocidad.ps1 (AWS).
    2. Ejecuta el test de velocidad del motor de Eureka_CloudSpeed contra cada región.
    3. Borra los recursos con -Eliminar -Confirmar y comprueba que no queda nada:
       - AWS: ningún bucket cspeed-* en la cuenta;
       - Azure: el grupo de recursos ya no existe (espera a que Azure termine de borrarlo).
    Requisitos: sesión iniciada antes (aws login --region <región> / az login).
.EXAMPLE
    .\Probar-Velocidad.ps1 -Nube AWS -Region eu-north-1
.EXAMPLE
    .\Probar-Velocidad.ps1 -Nube Azure -Region westeurope
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('AWS', 'Azure')][string]$Nube,
    [string]$Region,
    [ValidateRange(4, 30)][int]$Segundos = 8,
    [ValidateRange(10, 1024)][int]$TamanoMiB = 50,
    [string]$GrupoRecursos = 'rg-eureka-cloudspeed',
    # Azure: directorio (tenant) donde está la suscripción de pruebas
    [string]$Tenant,
    # Al terminar: mantener la sesión de la CLI iniciada o cerrarla. Si no indicas ninguno, se pregunta.
    [switch]$MantenerSesion,
    [switch]$CerrarSesion
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
# La consola puede haberse abierto antes de instalar las CLI: se recarga la ruta de programas
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $Region) { $Region = if ($Nube -eq 'AWS') { 'eu-north-1' } else { 'westeurope' } }
$create = if ($Nube -eq 'AWS') { Join-Path $here 'Crear-BucketsVelocidad.ps1' } else { Join-Path $here 'Crear-CuentasVelocidad.ps1' }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }

$created = $false
$result = $null
try {
    Write-Step "Creando el almacenamiento de prueba en $Nube ($Region)"
    $created = $true   # a partir de aquí, pase lo que pase, se intenta borrar
    $createArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $create, '-Regiones', $Region, '-TamanoMiB', $TamanoMiB)
    if ($Nube -eq 'Azure' -and $Tenant) { $createArgs += @('-Tenant', $Tenant) }
    & $ps @createArgs
    if ($LASTEXITCODE) { throw "La creación falló (código $LASTEXITCODE)." }

    Write-Step "Midiendo latencia, descarga y subida ($Segundos s por etapa)"
    Import-Module (Join-Path $root 'Modules\Core.psm1') -Force -DisableNameChecking
    Import-CsEngine
    $cfg = Join-Path (Get-CsFolder Config) 'velocidad.json'
    $e = (Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).endpoints | Where-Object { $_.cloud -eq $Nube -and $_.code -eq $Region } | Select-Object -First 1
    if (-not $e) { throw "No se encontró el endpoint de $Nube $Region en la configuración." }
    $ep = New-Object CloudSpeed.SpeedEndpoint
    $ep.Cloud = $e.cloud; $ep.Code = $e.code; $ep.Name = $e.name; $ep.UploadKind = $e.uploadKind
    $ep.DownloadUrl = Unprotect-CsSecret $e.downloadUrl; $ep.UploadUrl = Unprotect-CsSecret $e.uploadUrl
    $t = New-Object CloudSpeed.SpeedTest
    $t.Streams = 4; $t.Seconds = $Segundos; $t.MaxBytesPerStage = 200MB
    $t.Start($ep, $true, $true, $true)
    while ($t.IsRunning) { Start-Sleep -Milliseconds 1000; Write-Host ("  {0,-10} {1,5:P0} {2,8:0.0} Mbps" -f $t.Stage, $t.StageProgress, $t.CurrentMbps) }
    $l = $null; while ($t.Log.TryDequeue([ref]$l)) { Write-Host "  · $l" -ForegroundColor DarkYellow }
    $result = $t.Result
}
catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
finally {
    # Las CLI escriben avisos por la salida de errores: aquí no deben interrumpir la limpieza
    $ErrorActionPreference = 'Continue'
    if ($created) {
        # Sin sesión iniciada no se ha podido crear nada (y borrar pediría otro inicio de sesión)
        if ($Nube -eq 'AWS') { & aws sts get-caller-identity 2>&1 | Out-Null } else { & az account show 2>&1 | Out-Null }
        $session = $LASTEXITCODE -eq 0
        if (-not $session) {
            Write-Step 'Sin sesión en la nube: no se ha creado nada, no hay nada que borrar'
        }
        else {
            Write-Step "Borrando todo lo creado en $Nube"
            try { & $ps -NoProfile -ExecutionPolicy Bypass -File $create -Eliminar -Confirmar | Out-Host } catch { Write-Host "ERROR al borrar: $($_.Exception.Message)" -ForegroundColor Red }
            Write-Step 'Comprobando que no queda nada que genere cargos'
            if ($Nube -eq 'AWS') {
                $left = ((& aws s3api list-buckets --query "Buckets[?starts_with(Name,'cspeed-')].Name" --output text 2>&1) | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) { Write-Host "No se pudo comprobar: $left" -ForegroundColor Yellow }
                elseif ($left) { Write-Host "ATENCIÓN: siguen existiendo buckets: $left. Bórralos con: Crear-BucketsVelocidad.ps1 -Eliminar" -ForegroundColor Red }
                else { Write-Host 'AWS: no queda ningún bucket de prueba.' -ForegroundColor Green }
            }
            else {
                $exists = ((& az group exists --name $GrupoRecursos 2>&1) | Out-String).Trim()
                if ($exists -eq 'true') {
                    Write-Host "Esperando a que Azure termine de borrar $GrupoRecursos…"
                    & az group wait --deleted --name $GrupoRecursos --timeout 900 2>&1 | Out-Null
                    $exists = ((& az group exists --name $GrupoRecursos 2>&1) | Out-String).Trim()
                }
                if ($exists -eq 'true') { Write-Host "ATENCIÓN: el grupo $GrupoRecursos sigue existiendo. Bórralo con: Crear-CuentasVelocidad.ps1 -Eliminar" -ForegroundColor Red }
                elseif ($exists -eq 'false') { Write-Host 'Azure: el grupo de recursos de prueba ya no existe.' -ForegroundColor Green }
                else { Write-Host "No se pudo comprobar: $exists" -ForegroundColor Yellow }
            }
        }
    }
}

if ($result) {
    Write-Step "Resultado $Nube $Region"
    $result | Format-List LatencyMs, JitterMs, DownMbps, DownMiB, DownLatencyMs, UpMbps, UpMiB, UpLatencyMs, Error | Out-Host
}

# ------------------------------------------------------------------ sesión de la CLI
# Con cuentas de prueba y varios directorios (tenants) conviene no dejar sesiones abiertas sin querer.
$cli = if ($Nube -eq 'AWS') { 'AWS CLI' } else { 'Azure CLI' }
$keep = $null
if ($MantenerSesion) { $keep = $true } elseif ($CerrarSesion) { $keep = $false }
else {
    $ans = Read-Host "`n¿Mantener la sesión de $cli iniciada en este equipo? (S = mantener / N = cerrarla)"
    $keep = $ans -match '^\s*[sSyY]'
}
if ($keep) {
    Write-Host "Sesión de $cli mantenida. Ciérrala cuando quieras con: $(if ($Nube -eq 'AWS') { 'aws logout' } else { 'az logout' })" -ForegroundColor Yellow
}
else {
    if ($Nube -eq 'AWS') { & aws logout 2>&1 | Out-Null } else { & az logout 2>&1 | Out-Null; & az account clear 2>&1 | Out-Null }
    Write-Host "Sesión de $cli cerrada: las credenciales en caché de este equipo se han borrado." -ForegroundColor Green
}

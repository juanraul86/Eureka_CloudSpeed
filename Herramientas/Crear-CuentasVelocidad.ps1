<#
.SYNOPSIS
    Crea en tu suscripción de Azure las cuentas de almacenamiento que usa el test de velocidad de
    Eureka_CloudSpeed (una por región) y guarda sus URL, cifradas, en Config\velocidad.json.
.DESCRIPTION
    Necesita Azure CLI (az) y una sesión iniciada con permiso para crear recursos. Por cada región:
      - cuenta StorageV2 Standard_LRS: solo HTTPS, TLS 1.2 mínimo, sin acceso anónimo, sin replicación
        entre inquilinos, etiquetada app=Eureka_CloudSpeed;
      - contenedor "descarga" con un archivo aleatorio de -TamanoMiB (100 MiB por defecto);
      - contenedor "subida" con una regla de ciclo de vida que borra lo subido al día siguiente;
      - SAS ligadas a POLÍTICAS DE ACCESO ALMACENADAS ("lectura": solo leer; "escritura": crear, escribir y
        borrar, sin listar ni leer). Se revocan al instante con -Revocar y se amplían con -Renovar.
    Las URL se cifran con DPAPI (solo tu usuario de Windows en este equipo puede leerlas).
    Coste: céntimos al mes por región más el tráfico de salida de las descargas.
.EXAMPLE
    .\Crear-CuentasVelocidad.ps1 -Regiones westeurope,spaincentral,northeurope
.EXAMPLE
    .\Crear-CuentasVelocidad.ps1 -Renovar          # amplía la caducidad de las SAS existentes
.EXAMPLE
    .\Crear-CuentasVelocidad.ps1 -Revocar          # invalida todas las SAS al momento
.EXAMPLE
    .\Crear-CuentasVelocidad.ps1 -RotarClaves      # regenera las claves de las cuentas y vuelve a crear las SAS
.EXAMPLE
    .\Crear-CuentasVelocidad.ps1 -Eliminar         # borra el grupo de recursos completo
#>
[CmdletBinding(DefaultParameterSetName = 'Crear')]
param(
    [Parameter(ParameterSetName = 'Crear')][string[]]$Regiones = @('westeurope', 'spaincentral'),
    [string]$GrupoRecursos = 'rg-eureka-cloudspeed',
    [Parameter(ParameterSetName = 'Crear')][ValidateRange(10, 1024)][int]$TamanoMiB = 100,
    [ValidateRange(1, 365)][int]$DiasSas = 90,
    [string]$Suscripcion,
    # Directorio (tenant) de Microsoft Entra ID: id o dominio (p. ej. contoso.onmicrosoft.com). Útil si tu
    # cuenta está en varios directorios y la suscripción de pruebas no está en el predeterminado.
    [string]$Tenant,
    [Parameter(ParameterSetName = 'Renovar')][switch]$Renovar,
    [Parameter(ParameterSetName = 'Revocar')][switch]$Revocar,
    [Parameter(ParameterSetName = 'Rotar')][switch]$RotarClaves,
    [Parameter(ParameterSetName = 'Eliminar')][switch]$Eliminar,
    # Con -Eliminar: borra sin pedir que escribas SI (para pruebas automáticas)
    [Parameter(ParameterSetName = 'Eliminar')][switch]$Confirmar
)
$ErrorActionPreference = 'Stop'
$Regiones = @($Regiones | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -match '^[a-z0-9]+$' })
$root = Split-Path $PSScriptRoot -Parent
$dataRoot = if ($env:CFG_DATA) { $env:CFG_DATA } else { $root }
$cfgDir = Join-Path $dataRoot 'Config'
$cfg = Join-Path $cfgDir 'velocidad.json'
$tag = 'Crear-CuentasVelocidad'

Add-Type -AssemblyName System.Security
$entropy = [Text.Encoding]::UTF8.GetBytes('Eureka_CloudSpeed/velocidad/v1')
function Protect-Url([string]$t) { 'dpapi:' + [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $entropy, 'CurrentUser')) }

function Invoke-Az {
    # Los avisos de az van a la salida de errores: no deben detener el script (solo el código de salida cuenta)
    $ErrorActionPreference = 'Continue'
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $txt = ($out | Out-String).Trim()
        if ($txt -match 'locationineligible|not accepting new customers') {
            throw "Azure no admite clientes nuevos en esa región para esta suscripción. Prueba otra (por ejemplo -Regiones spaincentral o swedencentral)."
        }
        throw "az $($args[0..2] -join ' ') … falló:`n$txt"
    }
    return ($out | Where-Object { $_ -is [string] }) -join "`n"
}

function Save-Config($new, [string[]]$replaceCodes) {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $old = @()
    if (Test-Path $cfg) {
        try { $old = @((Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).endpoints | Where-Object { $_ -and -not ($_.cloud -eq 'Azure' -and $_.code -in $replaceCodes) -and [string]$_.downloadUrl -notmatch '<' }) }
        catch { throw "No se puede leer $cfg ($($_.Exception.Message)); no se modifica." }
        Copy-Item $cfg "$cfg.bak" -Force
        try { & icacls.exe "$cfg.bak" /inheritance:r /grant:r "$($env:USERNAME):(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null } catch { }
    }
    $all = @(@($old) + @($new) | Where-Object { $null -ne $_ -and $_.code })
    $tmpCfg = "$cfg.tmp"
    [pscustomobject]@{ endpoints = $all } | ConvertTo-Json -Depth 5 | Set-Content $tmpCfg -Encoding UTF8
    Move-Item $tmpCfg $cfg -Force   # escritura atómica: nunca queda un archivo a medias
    # Permisos: solo el usuario actual (además de SYSTEM y Administradores)
    try { & icacls.exe $cfg /inheritance:r /grant:r "$($env:USERNAME):(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null } catch { }
}

function Get-Accounts {
    $j = Invoke-Az storage account list --resource-group $GrupoRecursos --query "[?tags.app=='Eureka_CloudSpeed'].{name:name, location:location}" -o json
    @($j | ConvertFrom-Json)
}

function Set-Policies([string]$name, [string]$key, [string]$expiry, [switch]$Create) {
    $verb = if ($Create) { 'create' } else { 'update' }
    Invoke-Az storage container policy $verb --container-name descarga --name lectura --permissions r --expiry $expiry --account-name $name --account-key $key -o none | Out-Null
    Invoke-Az storage container policy $verb --container-name subida --name escritura --permissions cwd --expiry $expiry --account-name $name --account-key $key -o none | Out-Null
}

function New-Endpoint([string]$name, [string]$reg, [string]$key, [string]$blob, [string]$expiry, $catalog) {
    $sasR = Invoke-Az storage blob generate-sas --container-name descarga --name $blob --policy-name lectura --https-only --account-name $name --account-key $key -o tsv
    $sasW = Invoke-Az storage container generate-sas --name subida --policy-name escritura --https-only --account-name $name --account-key $key -o tsv
    $info = $catalog | Where-Object code -eq $reg | Select-Object -First 1
    [pscustomobject]@{
        cloud = 'Azure'; code = $reg; name = $(if ($info) { $info.name } else { $reg })
        downloadUrl = Protect-Url "https://$name.blob.core.windows.net/descarga/$blob`?$sasR"
        uploadUrl = Protect-Url "https://$name.blob.core.windows.net/subida`?$sasW"
        uploadKind = 'azure-container'; createdBy = $tag; account = $name; expires = $expiry
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'No se encuentra Azure CLI (az). Instálalo con: winget install -e --id Microsoft.AzureCLI  (y abre una consola nueva)'
}
$acct = $null
try { $acct = Invoke-Az account show -o json | ConvertFrom-Json } catch { }
if (-not $acct -or ($Tenant -and $acct.tenantId -ne $Tenant -and $acct.tenantDefaultDomain -ne $Tenant)) {
    Write-Host ('Inicia sesión en Azure en el navegador' + $(if ($Tenant) { " (directorio $Tenant)" }) + '…') -ForegroundColor Yellow
    $loginArgs = @('login', '-o', 'none'); if ($Tenant) { $loginArgs += @('--tenant', $Tenant) }
    try { Invoke-Az @loginArgs | Out-Null }
    catch {
        if ($_.Exception.Message -match 'No subscriptions found') {
            throw "Has iniciado sesión, pero ningún directorio de tu cuenta tiene una suscripción de Azure. Créala en el portal (Suscripciones > Agregar: evaluación gratuita o pago por uso) o indica otro directorio con -Tenant."
        }
        throw
    }
    try { $acct = Invoke-Az account show -o json | ConvertFrom-Json }
    catch { throw 'Has iniciado sesión, pero ese directorio no tiene ninguna suscripción de Azure. Crea una (Suscripciones > Agregar) o indica otro directorio con -Tenant.' }
}
if ($Suscripcion) { Invoke-Az account set --subscription $Suscripcion | Out-Null; $acct = Invoke-Az account show -o json | ConvertFrom-Json }
Write-Host "Suscripción: $($acct.name)" -ForegroundColor Cyan
$expiry = (Get-Date).ToUniversalTime().AddDays($DiasSas).ToString('yyyy-MM-ddTHH:mmZ')
$catalog = (Get-Content (Join-Path $root 'Catalog\regions.json') -Raw -Encoding UTF8 | ConvertFrom-Json).regions | Where-Object cloud -eq 'Azure'

switch ($PSCmdlet.ParameterSetName) {
    'Eliminar' {
        if ((Invoke-Az group exists --name $GrupoRecursos) -ne 'true') { Write-Host "El grupo $GrupoRecursos no existe."; return }
        $ok = if ($Confirmar) { 'SI' } else { Read-Host "Se borrará el grupo de recursos $GrupoRecursos con TODAS sus cuentas. Escribe SI para continuar" }
        if (-not $Confirmar -and $ok -cne 'SI') { Write-Host 'Cancelado.'; return }
        Invoke-Az group delete --name $GrupoRecursos --yes --no-wait | Out-Null
        Save-Config @() @($catalog.code)
        Write-Host 'Borrado solicitado (tarda unos minutos). Endpoints de Azure quitados de la configuración.' -ForegroundColor Green
        return
    }
    'Revocar' {
        foreach ($a in Get-Accounts) {
            $key = Invoke-Az storage account keys list --account-name $a.name --resource-group $GrupoRecursos --query '[0].value' -o tsv
            foreach ($c in @(@('descarga', 'lectura'), @('subida', 'escritura'))) {
                Invoke-Az storage container policy delete --container-name $c[0] --name $c[1] --account-name $a.name --account-key $key -o none | Out-Null
            }
            Write-Host "$($a.name): SAS revocadas."
        }
        Write-Host 'Todas las SAS dejan de funcionar en unos segundos. Usa -Renovar para volver a habilitarlas.' -ForegroundColor Green
        return
    }
    'Renovar' {
        $new = @()
        foreach ($a in Get-Accounts) {
            $key = Invoke-Az storage account keys list --account-name $a.name --resource-group $GrupoRecursos --query '[0].value' -o tsv
            $exists = @((Invoke-Az storage container policy list --container-name descarga --account-name $a.name --account-key $key -o json | ConvertFrom-Json).PSObject.Properties.Name) -contains 'lectura'
            Set-Policies $a.name $key $expiry -Create:(-not $exists)
            $blob = Invoke-Az storage blob list --container-name descarga --account-name $a.name --account-key $key --query '[0].name' -o tsv
            $new += New-Endpoint $a.name $a.location $key $blob $expiry $catalog
            Write-Host "$($a.name): válido hasta $expiry"
        }
        Save-Config $new @($new.code)
        Write-Host "SAS renovadas hasta $expiry." -ForegroundColor Green
        return
    }
    'Rotar' {
        $new = @()
        foreach ($a in Get-Accounts) {
            Invoke-Az storage account keys renew --account-name $a.name --resource-group $GrupoRecursos --key key1 -o none | Out-Null
            Invoke-Az storage account keys renew --account-name $a.name --resource-group $GrupoRecursos --key key2 -o none | Out-Null
            $key = Invoke-Az storage account keys list --account-name $a.name --resource-group $GrupoRecursos --query '[0].value' -o tsv
            $blob = Invoke-Az storage blob list --container-name descarga --account-name $a.name --account-key $key --query '[0].name' -o tsv
            $new += New-Endpoint $a.name $a.location $key $blob $expiry $catalog
            Write-Host "$($a.name): claves regeneradas (las SAS anteriores ya no sirven)."
        }
        Save-Config $new @($new.code)
        return
    }
}

# ------------------------------------------------------------------ crear
# Las suscripciones recién creadas no tienen registrado el proveedor de almacenamiento
# (Azure responde "SubscriptionNotFound" al crear la cuenta). Registrarlo es gratuito y solo hace falta una vez.
if ((Invoke-Az provider show -n Microsoft.Storage --query registrationState -o tsv).Trim() -ne 'Registered') {
    Write-Host 'Registrando el proveedor Microsoft.Storage en la suscripción (solo la primera vez, ~1 min)…'
    Invoke-Az provider register -n Microsoft.Storage --wait -o none | Out-Null
}
Write-Host "Grupo de recursos: $GrupoRecursos ($($Regiones[0]))"
Invoke-Az group create --name $GrupoRecursos --location $Regiones[0] --tags app=Eureka_CloudSpeed -o none | Out-Null

$tmp = Join-Path $env:TEMP "cloudspeed-$TamanoMiB.bin"
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -ne $TamanoMiB * 1MB) {
    Write-Host "Generando archivo de prueba aleatorio de $TamanoMiB MiB…"
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] (1MB)
    $fs = [IO.File]::Create($tmp)
    try { for ($i = 0; $i -lt $TamanoMiB; $i++) { $rng.GetBytes($buf); $fs.Write($buf, 0, $buf.Length) } } finally { $fs.Close() }
}
$policy = Join-Path $env:TEMP 'cloudspeed-policy.json'
@'
{ "rules": [ { "enabled": true, "name": "borrar-subidas", "type": "Lifecycle",
  "definition": { "actions": { "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 1 } } },
                  "filters": { "blobTypes": [ "blockBlob" ], "prefixMatch": [ "subida/" ] } } } ] }
'@ | Set-Content $policy -Encoding ASCII

$sha = [Security.Cryptography.SHA256]::Create()
$new = @()
foreach ($reg in $Regiones) {
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($acct.id)|$reg"))) -replace '-', '').Substring(0, 8).ToLower()
    $name = 'csp' + $reg + $hash
    if ($name.Length -gt 24) { $name = 'csp' + $reg.Substring(0, 13) + $hash }
    Write-Host "`n== $reg -> $name" -ForegroundColor Cyan
    Invoke-Az storage account create --name $name --resource-group $GrupoRecursos --location $reg --sku Standard_LRS --kind StorageV2 `
        --min-tls-version TLS1_2 --allow-blob-public-access false --https-only true --allow-cross-tenant-replication false `
        --public-network-access Enabled --tags app=Eureka_CloudSpeed -o none | Out-Null
    $key = Invoke-Az storage account keys list --account-name $name --resource-group $GrupoRecursos --query '[0].value' -o tsv
    foreach ($c in 'descarga', 'subida') { Invoke-Az storage container create --name $c --public-access off --account-name $name --account-key $key -o none | Out-Null }
    Set-Policies $name $key $expiry -Create
    $blob = "prueba-$($TamanoMiB)MiB.bin"
    Write-Host "Subiendo $blob…"
    Invoke-Az storage blob upload --container-name descarga --name $blob --file $tmp --account-name $name --account-key $key --overwrite -o none | Out-Null
    Invoke-Az storage account management-policy create --account-name $name --resource-group $GrupoRecursos --policy "@$policy" -o none | Out-Null
    $new += New-Endpoint $name $reg $key $blob $expiry $catalog
}
Save-Config $new $Regiones
Write-Host "`nListo: $($new.Count) región(es) en $cfg (URL cifradas, válidas hasta $expiry)." -ForegroundColor Green
Write-Host 'En Eureka_CloudSpeed pulsa Recargar en la sección Velocidad. Para invalidar todo al momento: -Revocar.'

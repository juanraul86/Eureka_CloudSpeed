# Velocidad.ps1 - Test de velocidad (latencia, jitter, descarga y subida) a una región.

function Get-CsSpeedConfigPath { Join-Path (Get-CsFolder Config) 'velocidad.json' }

function Get-CsSpeedEndpoints {
    <# Lee Config\velocidad.json. Las URL con firma (SAS o S3) se guardan cifradas con DPAPI: si alguna
       está en texto plano (pegada a mano), se cifra en ese momento y se reescribe el archivo. #>
    $list = New-Object 'System.Collections.Generic.List[CloudSpeed.SpeedEndpoint]'
    $p = Get-CsSpeedConfigPath
    if (-not (Test-Path $p)) { return , $list }
    $notes = @()
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $rewrite = $false
        foreach ($e in $j.endpoints) {
            foreach ($k in 'downloadUrl', 'uploadUrl') {
                $v = [string]$e.$k
                if ($v -and -not $v.StartsWith('dpapi:') -and (Test-CsSecretUrl $v) -and $v -notmatch '<|>') { $e.$k = Protect-CsSecret $v; $rewrite = $true }
            }
        }
        if ($rewrite) {
            $j | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding UTF8
            $notes += 'Las URL con firma se han cifrado (DPAPI) en Config\velocidad.json.'
        }
        foreach ($e in $j.endpoints) {
            if (-not $e.downloadUrl -and -not $e.uploadUrl) { continue }
            if ([string]$e.downloadUrl -match '<|>' -or [string]$e.uploadUrl -match '<|>') { continue }   # plantilla sin rellenar
            $x = New-Object CloudSpeed.SpeedEndpoint
            $x.Cloud = $e.cloud; $x.Code = $e.code; $x.Name = $(if ($e.name) { $e.name } else { $e.code })
            try { $x.DownloadUrl = Unprotect-CsSecret ([string]$e.downloadUrl); $x.UploadUrl = Unprotect-CsSecret ([string]$e.uploadUrl) }
            catch { $notes += "$($x.Name): no se pueden descifrar las URL (se cifraron con otro usuario o equipo). Vuelve a generarlas."; continue }
            $x.UploadKind = $(if ($e.uploadKind) { $e.uploadKind } else { 'url' })
            if ($e.expires) {
                $exp = [datetime]::MinValue
                if ([datetime]::TryParse([string]$e.expires, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$exp)) {
                    if ($exp -lt [datetime]::UtcNow) { $x.Name += ' (caducado)'; $notes += "$($e.name): las URL caducaron el $($exp.ToLocalTime().ToString('dd/MM/yyyy')). Renueva con el script (-Renovar)." }
                    elseif ($exp -lt [datetime]::UtcNow.AddDays(3)) { $notes += "$($e.name): las URL caducan el $($exp.ToLocalTime().ToString('dd/MM/yyyy HH:mm'))." }
                }
            }
            $list.Add($x)
        }
    }
    catch { $notes += "Config\velocidad.json no es válido: $($_.Exception.Message)" }
    if ($notes) { Set-CsStatus ($notes -join ' ') }
    , $list
}

function Get-CsSpeedConfigStamp {
    $p = Get-CsSpeedConfigPath
    if (Test-Path $p) { return (Get-Item $p).LastWriteTimeUtc.Ticks } else { return 0 }
}

function Update-CsSpeedRegions {
    $u = $script:Ui
    if ($script:Speed) { $script:Speed.CfgStamp = Get-CsSpeedConfigStamp; $script:Speed.CfgCheck = Get-Date }
    $eps = Get-CsSpeedEndpoints
    $u.CmbSpeedRegion.ItemsSource = $eps
    if ($eps.Count -gt 0) { $u.CmbSpeedRegion.SelectedIndex = 0 }
    $u.TxtSpeedNoEp.Visibility = $(if ($eps.Count -eq 0) { 'Visible' } else { 'Collapsed' })
    $u.BtnSpeedStart.IsEnabled = $eps.Count -gt 0
    $u.BtnSpeedFile.IsEnabled = $eps.Count -gt 0
}

function Initialize-CsPageVelocidad {
    $u = $script:Ui
    $script:Speed = @{ Test = $null; Points = (New-Object 'System.Collections.Generic.List[CloudSpeed.SpeedPoint]'); LastDraw = [datetime]::MinValue
        History = (New-Object 'System.Collections.ObjectModel.ObservableCollection[CloudSpeed.SpeedResult]') }
    $u.GridSpeed.ItemsSource = $script:Speed.History
    # Historial guardado
    $hist = Join-Path (Get-CsFolder Datos) 'Velocidad.csv'
    if (Test-Path $hist) {
        foreach ($r in (Import-Csv $hist -Delimiter ';' | Select-Object -Last 200)) {
            $x = New-Object CloudSpeed.SpeedResult
            $x.Time = [datetime]::ParseExact($r.Fecha, 'yyyy-MM-dd HH:mm:ss', $null); $x.Region = $r.Region; $x.Mode = $r.Modo
            foreach ($k in @(@('LatencyMs', 'Latencia_ms'), @('JitterMs', 'Jitter_ms'), @('DownMbps', 'Descarga_Mbps'), @('UpMbps', 'Subida_Mbps'), @('DownLatencyMs', 'LatenciaCarga_ms'))) {
                if ($r.($k[1])) { $x.($k[0]) = [double]::Parse($r.($k[1]), [Globalization.CultureInfo]::InvariantCulture) }
            }
            if ($r.Descarga_MiB) { $x.DownMiB = [double]::Parse($r.Descarga_MiB, [Globalization.CultureInfo]::InvariantCulture) }
            $script:Speed.History.Insert(0, $x)
        }
    }
    Update-CsSpeedRegions
    $u.SldSpeedSecs.Add_ValueChanged({ $script:Ui.TxtSpeedSecs.Text = "$([int]$script:Ui.SldSpeedSecs.Value) s" })
    $u.SldSpeedCap.Add_ValueChanged({ $script:Ui.TxtSpeedCap.Text = "$([int]$script:Ui.SldSpeedCap.Value) MiB" })
    $u.BtnSpeedStart.Add_Click({ Start-CsSpeedTest })
    $u.BtnSpeedStop.Add_Click({ if ($script:Speed.Test) { $script:Speed.Test.Cancel() } })
    $u.BtnSpeedReload.Add_Click({ Update-CsSpeedRegions; Set-CsStatus 'Endpoints de velocidad recargados.' })
    $u.BtnSpeedConfig.Add_Click({ Edit-CsSpeedConfig })
    $u.BtnSpeedScript.Add_Click({ Show-CsSpeedScriptHelp 'Azure' })
    $u.BtnSpeedScriptAws.Add_Click({ Show-CsSpeedScriptHelp 'AWS' })
    $u.BtnSpeedFile.Add_Click({ Start-CsFileUpload })
    $u.BtnSpeedCsv.Add_Click({
            Export-CsObjects ($script:Speed.History | Select-Object @{n = 'Fecha'; e = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, Region, Mode, LatencyMs, JitterMs, DownMbps, UpMbps, DownLatencyMs, UpLatencyMs, DownMiB, UpMiB) ('Velocidad_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date))
        })
    $u.HostSpeed.Add_SizeChanged({ $script:G.PagesDirty = $true })
}

function Show-CsPageVelocidad {
    if ($script:Speed -and -not $script:Speed.Test -and (Get-CsSpeedConfigStamp) -ne $script:Speed.CfgStamp) { Update-CsSpeedRegions }
    $script:G.PagesDirty = $true
}

function Start-CsSpeedTest {
    $u = $script:Ui
    $ep = $u.CmbSpeedRegion.SelectedItem
    if (-not $ep) { Show-CsMessage 'Elige una región con endpoints configurados.' 'Warning'; return }
    if (-not ($u.ChkSpLat.IsChecked -or $u.ChkSpDown.IsChecked -or $u.ChkSpUp.IsChecked)) { Show-CsMessage 'Marca al menos una etapa.' 'Warning'; return }
    $t = New-Object CloudSpeed.SpeedTest
    $t.Streams = $(if ($u.RbSpeedMulti.IsChecked) { 4 } else { 1 })
    $t.Seconds = [int]$u.SldSpeedSecs.Value
    $t.MaxBytesPerStage = [long]$u.SldSpeedCap.Value * 1MB
    $script:Speed.Points.Clear()
    $script:Speed.Test = $t
    $u.TxtSpeedLog.Text = ''
    foreach ($n in 'SpLat', 'SpDown', 'SpUp') { $u[$n].Text = $(if ($n -eq 'SpLat') { '— ms' } else { '— Mbps' }) }
    $u.SpJit.Text = 'jitter —'; $u.SpDownSub.Text = ' '; $u.SpUpSub.Text = ' '
    $t.Start($ep, [bool]$u.ChkSpLat.IsChecked, [bool]$u.ChkSpDown.IsChecked, [bool]$u.ChkSpUp.IsChecked)
    $u.BtnSpeedStart.IsEnabled = $false; $u.BtnSpeedStop.IsEnabled = $true; $u.BtnSpeedFile.IsEnabled = $false
    Set-CsStatus "Test de velocidad a $($ep.Label)…"
}

function Update-CsPageVelocidad {
    $s = $script:Speed
    if (-not $s) { return }
    $u = $script:Ui
    $t = $s.Test
    # Si los scripts de Azure o AWS han cambiado la configuración, se recarga sola (cada 2 s, sin test en curso)
    if (-not $t -and ((Get-Date) - $s.CfgCheck).TotalSeconds -ge 2) {
        $s.CfgCheck = Get-Date
        if ((Get-CsSpeedConfigStamp) -ne $s.CfgStamp) { Update-CsSpeedRegions; Set-CsStatus 'Configuración de velocidad actualizada: endpoints recargados.' }
    }
    if ($t) {
        $p = $null; while ($t.Points.TryDequeue([ref]$p)) { $s.Points.Add($p) }
        $l = $null; while ($t.Log.TryDequeue([ref]$l)) { $u.TxtSpeedLog.AppendText($l + [Environment]::NewLine); $u.TxtSpeedLog.ScrollToEnd() }
        $es = [Globalization.CultureInfo]'es-ES'
        $r = $t.Result
        if ($r) {
            if ($null -ne $r.LatencyMs) { $u.SpLat.Text = $r.LatencyMs.ToString('0.0', $es) + ' ms'; $u.SpJit.Text = 'jitter ' + $(if ($null -ne $r.JitterMs) { $r.JitterMs.ToString('0.0', $es) + ' ms' } else { '—' }) }
            if ($t.Stage -eq 'Descarga') { $u.SpDown.Text = $t.CurrentMbps.ToString('0.0', $es) + ' Mbps' }
            elseif ($null -ne $r.DownMbps) { $u.SpDown.Text = $r.DownMbps.ToString('0.0', $es) + ' Mbps'; $u.SpDownSub.Text = '{0:0} MiB · latencia con carga {1}' -f $r.DownMiB, $(if ($null -ne $r.DownLatencyMs) { "$($r.DownLatencyMs) ms" } else { '—' }) }
            if ($t.Stage -eq 'Subida') { $u.SpUp.Text = $t.CurrentMbps.ToString('0.0', $es) + ' Mbps' }
            elseif ($null -ne $r.UpMbps) { $u.SpUp.Text = $r.UpMbps.ToString('0.0', $es) + ' Mbps'; $u.SpUpSub.Text = '{0:0} MiB · latencia con carga {1}' -f $r.UpMiB, $(if ($null -ne $r.UpLatencyMs) { "$($r.UpLatencyMs) ms" } else { '—' }) }
        }
        $u.SpStage.Text = $t.Stage
        $u.SpProgress.Value = $t.StageProgress
        if (-not $t.IsRunning) {
            $s.Test = $null
            $u.BtnSpeedStart.IsEnabled = $true; $u.BtnSpeedStop.IsEnabled = $false; $u.BtnSpeedFile.IsEnabled = $true
            if ($r -and ($null -ne $r.LatencyMs -or $null -ne $r.DownMbps -or $null -ne $r.UpMbps)) {
                $s.History.Insert(0, $r)
                Save-CsSpeedResult $r
                Set-CsStatus ("Test de velocidad terminado: {0}" -f $r.Region)
            }
            else { Set-CsStatus 'Test de velocidad terminado sin resultados (revisa el registro).' }
        }
        $script:G.PagesDirty = $true
    }
    if ($script:G.PagesDirty -and ((Get-Date) - $s.LastDraw).TotalMilliseconds -gt 300) {
        $script:G.PagesDirty = $false; $s.LastDraw = Get-Date
        [CloudSpeed.Charts]::SpeedCurve($u.CanvasSpeed, $s.Points, $script:G.ChartTheme, $u.HostSpeed.ActualWidth, $u.HostSpeed.ActualHeight, [int]$u.SldSpeedSecs.Value)
    }
}

function Save-CsSpeedResult($r) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $f = { param($v) if ($null -eq $v) { '' } else { ([double]$v).ToString('0.##', $inv) } }
    [pscustomobject]@{
        Fecha = $r.Time.ToString('yyyy-MM-dd HH:mm:ss'); Region = $r.Region; Modo = $r.Mode; Equipo = (Get-CsMachine)
        Latencia_ms = & $f $r.LatencyMs; Jitter_ms = & $f $r.JitterMs; Descarga_Mbps = & $f $r.DownMbps; Subida_Mbps = & $f $r.UpMbps
        LatenciaCarga_ms = & $f $r.DownLatencyMs; LatenciaCargaSubida_ms = & $f $r.UpLatencyMs; Descarga_MiB = & $f $r.DownMiB; Subida_MiB = & $f $r.UpMiB
    } | Export-Csv -Path (Join-Path (Get-CsFolder Datos) 'Velocidad.csv') -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
}

function Stop-CsPageVelocidad { if ($script:Speed -and $script:Speed.Test) { $script:Speed.Test.Cancel() } }

function Edit-CsSpeedConfig {
    $p = Get-CsSpeedConfigPath
    if (-not (Test-Path $p)) { Copy-Item (Join-Path (Get-CsRoot) 'Catalog\velocidad.ejemplo.json') $p }
    Start-Process notepad.exe "`"$p`""
    Set-CsStatus 'Guarda el archivo y pulsa Recargar.'
}

function Show-CsSpeedScriptHelp([string]$Cloud = 'Azure') {
    $cfg = Get-CsSpeedConfigPath
    if ($Cloud -eq 'AWS') {
        $script = Join-Path (Get-CsRoot) 'Herramientas\Crear-BucketsVelocidad.ps1'
        $cmd = "powershell -ExecutionPolicy Bypass -File `"$script`" -Regiones eu-south-2,eu-west-1"
        $msg = @"
El script crea en TU cuenta de AWS, con AWS CLI (aws), un bucket de S3 por región con:
  • Block Public Access completo, cifrado SSE-S3 y política que exige TLS 1.2 o superior,
  • un objeto de prueba de 100 MiB para la descarga,
  • una regla que borra lo subido a las 24 horas,
  • URL prefirmadas (GET de la descarga y PUT de la subida),
y guarda las URL cifradas en:
  $cfg

AWS limita las URL prefirmadas a 7 días: renuévalas con -Renovar.
Requisitos: winget install -e --id Amazon.AWSCLI  y  aws configure  (o aws sso login).

Crear:    $cmd
Renovar:  ... -Renovar        Borrar:  ... -Eliminar

¿Copiar el comando al portapapeles?
"@
    }
    else {
        $script = Join-Path (Get-CsRoot) 'Herramientas\Crear-CuentasVelocidad.ps1'
        $cmd = "powershell -ExecutionPolicy Bypass -File `"$script`" -Regiones westeurope,spaincentral"
        $msg = @"
El script crea en TU suscripción de Azure, con Azure CLI (az), una cuenta de almacenamiento por región con:
  • solo HTTPS, TLS 1.2 y sin acceso anónimo,
  • un archivo de prueba de 100 MiB para la descarga,
  • un contenedor de subida que borra los datos a las 24 horas,
  • SAS ligadas a políticas de acceso revocables (lectura para la descarga; crear, escribir y borrar para la subida),
y guarda las URL cifradas en:
  $cfg

Requisitos: winget install -e --id Microsoft.AzureCLI  (te pedirá iniciar sesión).
Coste aproximado: céntimos al mes por región más el tráfico de salida (los primeros 100 GB al mes son gratis).

Crear:    $cmd
Renovar:  ... -Renovar     Revocar al momento:  ... -Revocar     Rotar claves:  ... -RotarClaves     Borrar:  ... -Eliminar

¿Copiar el comando al portapapeles?
"@
    }
    $r = [System.Windows.MessageBox]::Show($script:Ui.Window, $msg, "Crear endpoints de velocidad en $Cloud", 'YesNo', 'Information')
    if ($r -eq 'Yes') { Copy-CsText $cmd 'Comando' }
}

function Start-CsFileUpload {
    $ep = $script:Ui.CmbSpeedRegion.SelectedItem
    if (-not $ep -or -not $ep.UploadUrl) { Show-CsMessage 'La región elegida no tiene uploadUrl configurada.' 'Warning'; return }
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = 'Archivo de prueba (no confidencial)'
    if (-not $d.ShowDialog($script:Ui.Window)) { return }
    $file = $d.FileName
    $size = (Get-Item $file).Length
    $ok = [System.Windows.MessageBox]::Show($script:Ui.Window, ("Se subirá '{0}' ({1:N1} MiB) a {2} y se borrará al terminar.`n`nUsa solo datos que no sean confidenciales. ¿Continuar?" -f (Split-Path $file -Leaf), ($size / 1MB), $ep.Label), 'Subir archivo', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $script:Ui.BtnSpeedFile.IsEnabled = $false
    $script:Ui.TxtSpeedFile.Text = 'Subiendo…'
    [void](Start-CsJob -Status "Subiendo archivo a $($ep.Label)…" -Arguments @($ep, $file) -Script {
            param($ep, $file)
            [CloudSpeed.SpeedTest]::UploadFile($ep, $file, $null, [Threading.CancellationToken]::None)
        } -OnDone {
            param($r, $err)
            $script:Ui.BtnSpeedFile.IsEnabled = $true
            if ($err) { $script:Ui.TxtSpeedFile.Text = "Error: $err"; return }
            $mbps = [double]@($r)[0]
            $script:Ui.TxtSpeedFile.Text = 'Subida del archivo: {0:0.0} Mbps' -f $mbps
            Set-CsStatus $script:Ui.TxtSpeedFile.Text
        })
}

# Ayuda.ps1 - Sección de ayuda: plazo de conservación del histórico y borrado de los datos del usuario.

function Initialize-CsPageAyuda {
    $u = $script:Ui
    $cur = [int]$script:G.Retention
    $u.CmbRetention.SelectedItem = @($u.CmbRetention.Items | Where-Object { [int]$_.Tag -eq $cur })[0]
    if ($null -eq $u.CmbRetention.SelectedItem) { $u.CmbRetention.SelectedIndex = 2 }
    $u.CmbRetention.Add_SelectionChanged({
            $script:G.Retention = [int]$script:Ui.CmbRetention.SelectedItem.Tag
            $script:Ui.TxtPrivacy.Text = $(if ($script:G.Retention) { "Se conservarán $($script:G.Retention) meses de histórico." } else { 'El histórico se conservará sin límite: bórralo cuando ya no lo necesites.' })
        })
    $u.BtnPurgeNow.Add_Click({
            $n = Invoke-CsRetention ([int]$script:G.Retention)
            $script:Ui.TxtPrivacy.Text = "Hecho: $n registros antiguos borrados."
            Set-CsStatus $script:Ui.TxtPrivacy.Text
        })
    $u.BtnDeleteHistory.Add_Click({
            $r = [System.Windows.MessageBox]::Show($script:Ui.Window, "Se borrará todo el histórico de este equipo (mediciones, sesiones, tests de velocidad, estado de servicios) y las cachés descargadas.`n`nNo se tocan las exportaciones ni la configuración. No se puede deshacer. ¿Continuar?", 'Borrar el histórico', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            $n = Remove-CsHistory
            $script:IpData = $null
            $script:Ui.TxtPrivacy.Text = "Histórico borrado ($n elementos)."
            Set-CsStatus $script:Ui.TxtPrivacy.Text
        })
    $u.TxtPrivacy.Text = $(if ($cur) { "Se conservan $cur meses de histórico." } else { 'El histórico se conserva sin límite.' })
}

@echo off
rem ============================================================
rem  Eureka_CloudSpeed - lanzador portable (no necesita administrador)
rem  Doble clic: interfaz grafica.
rem  Con parametros: se pasan a Eureka_CloudSpeed.ps1, por ejemplo
rem     Eureka_CloudSpeed.cmd -SinInterfaz -Geografia Europa -Exportar Excel
rem  Los programas del sistema se llaman con su ruta completa para que
rem  un archivo con el mismo nombre en esta carpeta nunca se ejecute.
rem ============================================================
setlocal
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
cd /d "%SystemRoot%\System32"
if "%~1"=="" (
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Eureka_CloudSpeed.ps1" -OcultarConsola
) else (
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Eureka_CloudSpeed.ps1" %*
)
exit /b %errorlevel%

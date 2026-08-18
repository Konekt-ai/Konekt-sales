<#
    Konekt Sales - quitar el servicio de Windows

        powershell -ExecutionPolicy Bypass -File .\windows\desinstalar.ps1

    Detiene y borra la tarea programada y la regla del firewall.
    Corre esto cuando muevas el servicio a Linux, para que esta maquina deje
    de levantarlo sola al prender.

    NO borra el .env, los archivos del proyecto ni nada de Supabase.
#>

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$TAREA    = "KonektSales"
$PUERTO   = 3000
$REGLA_FW = "Konekt Sales ($PUERTO)"
$APP      = Split-Path $PSScriptRoot -Parent

function Verde  { param($t) Write-Host $t -ForegroundColor Green }
function Amaril { param($t) Write-Host $t -ForegroundColor Yellow }
function Rojo   { param($t) Write-Host $t -ForegroundColor Red }

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { Rojo "Abre PowerShell como administrador."; exit 1 }

Write-Host ""

$tarea = Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
if ($tarea) {
    Stop-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false
    Verde "Tarea '$TAREA' eliminada."
} else {
    Amaril "No habia tarea registrada."
}

# La tarea lanza cmd, que a su vez lanza node: al detener la tarea puede
# quedar el node suelto. Se cierra solo el que esta corriendo este server.js.
$rutaServer = Join-Path $APP "server.js"
$sueltos = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
           Where-Object { $_.CommandLine -and $_.CommandLine -like "*server.js*" }
foreach ($p in $sueltos) {
    try {
        Stop-Process -Id $p.ProcessId -Force
        Verde ("Proceso node suelto cerrado (PID " + $p.ProcessId + ").")
    } catch {
        Amaril ("No se pudo cerrar el PID " + $p.ProcessId)
    }
}

$regla = Get-NetFirewallRule -DisplayName $REGLA_FW -ErrorAction SilentlyContinue
if ($regla) {
    Remove-NetFirewallRule -DisplayName $REGLA_FW
    Verde "Regla del firewall eliminada."
} else {
    Amaril "No habia regla de firewall."
}

Write-Host ""
Verde "Konekt Sales ya no arranca solo en esta maquina."
Write-Host ""
Write-Host "  El .env, el proyecto y los datos en Supabase siguen intactos."
Write-Host "  Para volver a instalarlo aqui:  .\install-windows.ps1"
Write-Host "  Para pasarlo a Linux:           ver DEPLOY.md"
Write-Host ""

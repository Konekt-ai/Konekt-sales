<#
    Konekt Sales - actualizar en Windows

        powershell -ExecutionPolicy Bypass -File .\windows\actualizar.ps1

    Trae los cambios, reinstala dependencias solo si cambiaron, reinicia el
    servicio y comprueba que responda. Si no responde, regresa a la version
    anterior.
#>

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$TAREA  = "KonektSales"
$APP    = Split-Path $PSScriptRoot -Parent
$PUERTO = 3000

function Verde  { param($t) Write-Host $t -ForegroundColor Green }
function Amaril { param($t) Write-Host $t -ForegroundColor Yellow }
function Rojo   { param($t) Write-Host $t -ForegroundColor Red }

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { Rojo "Abre PowerShell como administrador."; exit 1 }

Set-Location $APP

$anterior = (& git rev-parse HEAD).Trim()
Write-Host ("Version actual: " + (& git log -1 --format='%h %s'))

Write-Host ""
Write-Host "Trayendo cambios..."
& git fetch --quiet origin
$nuevo = (& git rev-parse '@{u}').Trim()

if ($anterior -eq $nuevo) {
    Verde "Ya estas en la ultima version. No hay nada que hacer."
    exit 0
}

& git merge --ff-only '@{u}'
if ($LASTEXITCODE -ne 0) { Rojo "El merge fallo. Hay cambios locales sin guardar?"; exit 1 }
Verde ("Actualizado a: " + (& git log -1 --format='%h %s'))

# npm ci borra y rehace node_modules completo; en una maquina lenta eso tarda,
# asi que solo se hace si de verdad cambiaron las dependencias.
& git diff --quiet $anterior HEAD -- package-lock.json package.json
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Cambiaron las dependencias, reinstalando..."
    & npm ci --omit=dev --no-audit --no-fund
} else {
    Write-Host "Las dependencias no cambiaron."
}

Write-Host ""
Write-Host "Reiniciando el servicio..."
Stop-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $TAREA
Start-Sleep -Seconds 6

$salud = $null
try { $salud = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO/api/health" -TimeoutSec 8 } catch { $salud = $null }

if ($salud -and $salud.ok) {
    Verde "Listo. El servicio quedo corriendo."
    exit 0
}

Rojo "El servicio no respondio bien despues de actualizar."
Amaril "Regresando a la version anterior..."

& git reset --hard $anterior
& npm ci --omit=dev --no-audit --no-fund
Stop-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $TAREA
Start-Sleep -Seconds 6

$salud2 = $null
try { $salud2 = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO/api/health" -TimeoutSec 8 } catch { $salud2 = $null }

if ($salud2) {
    Amaril "Se restauro la version anterior y el servicio esta arriba."
} else {
    Rojo "El servicio sigue caido. Revisa:  Get-Content '$APP\logs\konekt-sales.log' -Tail 40 -Encoding UTF8"
}
exit 1

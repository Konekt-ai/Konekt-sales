<#
    Konekt Sales - publicar en la red de Tailscale

        powershell -ExecutionPolicy Bypass -File .\windows\tailscale.ps1

    Deja la aplicacion accesible desde cualquier PC que este en el mismo
    tailnet, sin abrir puertos en el modem ni depender de la IP del ISP.

    Dos caminos:
      1. tailscale serve  ->  https://esta-pc.tu-tailnet.ts.net   (recomendado)
         Cifrado de verdad, con certificado valido, y no hace falta tocar el
         firewall: tailscaled habla con la app por 127.0.0.1.
      2. Acceso directo   ->  http://100.x.y.z:3000
         Mas simple de entender, pero va sin cifrar y hay que abrir el puerto.

    NUNCA uses "tailscale funnel": eso publica el sitio a INTERNET, no solo a
    tu tailnet, y esta aplicacion entra sin contrasena.
#>

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$PUERTO   = 3000
$REGLA_TS = "Konekt Sales - Tailscale ($PUERTO)"
# Rango CGNAT que Tailscale asigna a todos los nodos. Abrir solo esto deja
# entrar a los equipos del tailnet y a nadie mas.
$RANGO_TS = "100.64.0.0/10"

function Verde  { param($t) Write-Host $t -ForegroundColor Green }
function Azul   { param($t) Write-Host $t -ForegroundColor Cyan }
function Amaril { param($t) Write-Host $t -ForegroundColor Yellow }
function Rojo   { param($t) Write-Host $t -ForegroundColor Red }
function Paso   { param($t) Write-Host ""; Azul "== $t ==" }

# ------------------------------------------------------------------
Paso "Revisando Tailscale"

$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $ts) {
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe",
                     "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
        if (Test-Path $p) { $ts = @{ Source = $p }; break }
    }
}

if (-not $ts) {
    Rojo "Tailscale no esta instalado en esta maquina."
    Write-Host ""
    Write-Host "  Instalalo con:"
    Write-Host "    winget install --id tailscale.tailscale --source winget"
    Write-Host ""
    Write-Host "  O bajalo de https://tailscale.com/download/windows"
    Write-Host "  Luego inicia sesion con la cuenta de Konekt y vuelve a correr esto."
    exit 1
}
$TS = $ts.Source
Verde "Tailscale encontrado: $TS"

$crudo = & $TS status --json
if ($LASTEXITCODE -ne 0) {
    Rojo "No se pudo consultar el estado de Tailscale."
    Write-Host "  Abre la app de Tailscale e inicia sesion, luego reintenta."
    exit 1
}

$estado = $crudo | ConvertFrom-Json
if ($estado.BackendState -ne "Running") {
    Rojo "Tailscale esta instalado pero no conectado (estado: $($estado.BackendState))."
    Write-Host "  Abre la app de Tailscale, inicia sesion y vuelve a correr esto."
    exit 1
}

$ipTS   = $estado.Self.TailscaleIPs | Where-Object { $_ -notmatch ":" } | Select-Object -First 1
$nombre = $estado.Self.DNSName.TrimEnd(".")

Verde "Conectado como: $nombre"
Verde "IP de Tailscale: $ipTS"

# ------------------------------------------------------------------
Paso "Revisando que la aplicacion este arriba"

$salud = $null
try { $salud = Invoke-RestMethod "http://127.0.0.1:$PUERTO/api/health" -TimeoutSec 6 } catch { }
if (-not $salud) {
    Rojo "Konekt Sales no responde en el puerto $PUERTO."
    Write-Host "  Arrancalo con:  Start-ScheduledTask -TaskName KonektSales"
    exit 1
}
Verde "La aplicacion responde."
if ($salud.sinLogin) {
    Amaril "Ojo: esta en modo SIN LOGIN. Cualquiera de tu tailnet entra sin contrasena."
}

# ------------------------------------------------------------------
Paso "Como quieres publicarla"

Write-Host "  1) tailscale serve  - https con certificado, sin tocar el firewall  [recomendado]"
Write-Host "  2) Acceso directo   - http://${ipTS}:$PUERTO, hay que abrir el puerto"
Write-Host ""
$opcion = Read-Host "Opcion [1]"
if (-not $opcion) { $opcion = "1" }

if ($opcion -eq "1") {
    # --------------------------------------------------------------
    Paso "Publicando con tailscale serve"

    # --bg lo deja corriendo en segundo plano y sobrevive al cierre de esta
    # ventana. La configuracion la guarda tailscaled, asi que aguanta reinicios.
    & $TS serve --bg $PUERTO
    if ($LASTEXITCODE -ne 0) {
        Rojo "tailscale serve fallo."
        Write-Host ""
        Write-Host "  La causa mas comun: faltan MagicDNS y los certificados HTTPS."
        Write-Host "  Actívalos en https://login.tailscale.com/admin/dns"
        Write-Host "    - MagicDNS: Enable"
        Write-Host "    - HTTPS Certificates: Enable"
        Write-Host "  Luego vuelve a correr esto."
        exit 1
    }

    Write-Host ""
    & $TS serve status
    Write-Host ""
    Verde "=================================================="
    Verde "  Abre desde cualquier PC del tailnet:"
    Verde "    https://$nombre"
    Verde "=================================================="
    Write-Host ""
    Write-Host "  Va cifrado con certificado valido, asi que el navegador no"
    Write-Host "  reclama. No hizo falta abrir ningun puerto."
    Write-Host ""
    Write-Host "  Para dejar de publicarla:  tailscale serve reset"

} else {
    # --------------------------------------------------------------
    Paso "Abriendo el puerto solo para el tailnet"

    $esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $esAdmin) {
        Rojo "Para tocar el firewall hace falta abrir PowerShell como administrador."
        exit 1
    }

    $vieja = Get-NetFirewallRule -DisplayName $REGLA_TS -ErrorAction SilentlyContinue
    if ($vieja) { Remove-NetFirewallRule -DisplayName $REGLA_TS }

    # Profile Any a proposito: Windows suele clasificar el adaptador de
    # Tailscale como red publica, y una regla limitada a Private/Domain no
    # aplicaria. Lo que acota el riesgo no es el perfil, es RemoteAddress:
    # solo entran direcciones del rango de Tailscale.
    New-NetFirewallRule -DisplayName $REGLA_TS -Direction Inbound -Protocol TCP `
        -LocalPort $PUERTO -RemoteAddress $RANGO_TS -Action Allow -Profile Any | Out-Null

    Verde "Puerto $PUERTO abierto solo para $RANGO_TS (equipos del tailnet)."
    Write-Host ""
    Verde "=================================================="
    Verde "  Abre desde cualquier PC del tailnet:"
    Verde "    http://${ipTS}:$PUERTO"
    Verde "    http://${nombre}:$PUERTO"
    Verde "=================================================="
    Write-Host ""
    Amaril "  Esto va SIN cifrar. Dentro del tailnet el trafico ya viaja cifrado"
    Amaril "  por WireGuard, asi que es aceptable; pero la opcion 1 es mejor."
}

Write-Host ""
Write-Host "  En las otras PCs: instala Tailscale, inicia sesion con la misma"
Write-Host "  cuenta de Konekt, y abre la direccion de arriba."
Write-Host ""
Amaril "  NUNCA uses 'tailscale funnel': eso lo publica a internet entero."
Write-Host ""

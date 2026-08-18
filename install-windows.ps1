<#
    Konekt Sales - instalacion en Windows 10 / 11

    Como correrlo (click derecho en PowerShell -> Ejecutar como administrador):

        cd C:\konekt-sales
        powershell -ExecutionPolicy Bypass -File .\install-windows.ps1

    Que hace:
      - Verifica o instala Node.js
      - Instala las dependencias del proyecto
      - Crea el archivo .env preguntandote las llaves
      - Registra una tarea programada que arranca el servicio al prender la PC
        y lo revive si se cae
      - Abre el puerto en el firewall para que lo vean desde la red local
      - Comprueba que quedo respondiendo

    Se puede volver a correr: no pisa un .env que ya exista.
#>

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$TAREA     = "KonektSales"
$APP       = $PSScriptRoot
$PUERTO    = 3000
$REGLA_FW  = "Konekt Sales ($PUERTO)"

function Verde  { param($t) Write-Host $t -ForegroundColor Green }
function Azul   { param($t) Write-Host $t -ForegroundColor Cyan }
function Amaril { param($t) Write-Host $t -ForegroundColor Yellow }
function Rojo   { param($t) Write-Host $t -ForegroundColor Red }
function Paso   { param($t) Write-Host ""; Azul "== $t ==" }
function Morir  { param($t) Rojo "ERROR: $t"; exit 1 }

# Escribe texto plano en UTF-8 SIN BOM. Set-Content -Encoding utf8 en
# PowerShell 5.1 mete un BOM, y dotenv leeria la primera variable con tres
# bytes basura pegados al nombre: el .env quedaria roto de forma silenciosa.
function EscribirTexto {
    param([string]$Ruta, [string]$Texto)
    $sinBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Ruta, $Texto, $sinBom)
}

# ------------------------------------------------------------------
Paso "Revisando el sistema"

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Morir "Abre PowerShell como administrador y vuelve a correrlo."
}

$so = Get-CimInstance Win32_OperatingSystem
Verde ("Sistema: " + $so.Caption)
Verde ("RAM: {0:N0} MB" -f ($so.TotalVisibleMemorySize / 1KB))

if (-not (Test-Path (Join-Path $APP "server.js"))) {
    Morir "No encuentro server.js en $APP. Corre el script desde la carpeta del proyecto."
}
Verde "Proyecto: $APP"

# ------------------------------------------------------------------
Paso "Node.js"

$nodeExe = $null
$cmdNode = Get-Command node -ErrorAction SilentlyContinue
if ($cmdNode) {
    $version = (& node -v).TrimStart("v")
    $mayor = [int]($version.Split(".")[0])
    if ($mayor -ge 18) {
        $nodeExe = $cmdNode.Source
        Verde "Node ya instalado: v$version"
    } else {
        Amaril "Node v$version es muy viejo, se necesita 18 o mas."
    }
}

if (-not $nodeExe) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Instalando Node.js LTS con winget..."
        winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
        # winget no refresca el PATH de esta sesion: se relee del registro.
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $cmdNode = Get-Command node -ErrorAction SilentlyContinue
        if ($cmdNode) { $nodeExe = $cmdNode.Source }
    }
    if (-not $nodeExe) {
        Morir "No se pudo instalar Node. Bajalo de https://nodejs.org (version LTS), reinicia PowerShell y vuelve a correr esto."
    }
    Verde "Node instalado: $(& node -v)"
}

# La tarea programada corre como SYSTEM, que tiene otro PATH: hay que
# guardar la ruta absoluta del ejecutable.
Verde "Ruta de node: $nodeExe"

# ------------------------------------------------------------------
Paso "Configuracion (.env)"

$rutaEnv = Join-Path $APP ".env"

if (Test-Path $rutaEnv) {
    Verde "Ya existe un .env. No lo toco."
} else {
    $plantilla = Join-Path $APP ".env.example"
    if (-not (Test-Path $plantilla)) { Morir "Falta .env.example" }

    Write-Host "Necesito tres datos. Puedes dejarlos vacios y editar el .env despues."
    Write-Host ""
    $vUrl  = Read-Host "  SUPABASE_URL      "
    $vAnon = Read-Host "  SUPABASE_ANON_KEY "
    $vAnt  = Read-Host "  ANTHROPIC_API_KEY "

    $txt = Get-Content $plantilla -Raw

    if ($vUrl)  { $txt = $txt -replace '(?m)^SUPABASE_URL=.*',      ("SUPABASE_URL=" + $vUrl) }
    if ($vAnon) { $txt = $txt -replace '(?m)^SUPABASE_ANON_KEY=.*', ("SUPABASE_ANON_KEY=" + $vAnon) }
    if ($vAnt)  { $txt = $txt -replace '(?m)^ANTHROPIC_API_KEY=.*', ("ANTHROPIC_API_KEY=" + $vAnt) }

    $txt = $txt -replace '(?m)^NODE_ENV=.*', 'NODE_ENV=production'
    # Sin nginx enfrente: Node atiende directo a la red local.
    $txt = $txt -replace '(?m)^HOST=.*', 'HOST=0.0.0.0'
    # Sin proxy, TRUST_PROXY debe quedar vacio. Si se activa sin proxy real,
    # cualquiera podria falsear X-Forwarded-For y saltarse el limite de uso.
    $txt = $txt -replace '(?m)^TRUST_PROXY=.*', '# TRUST_PROXY= (vacio: no hay proxy enfrente)'

    EscribirTexto -Ruta $rutaEnv -Texto $txt
    Verde ".env creado."
}

# Solo administradores y SYSTEM pueden leerlo: adentro van las llaves.
try {
    icacls $rutaEnv /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(F)" | Out-Null
    Verde "Permisos del .env restringidos."
} catch {
    Amaril "No se pudieron ajustar los permisos del .env. Revisalo a mano."
}

# ------------------------------------------------------------------
Paso "Dependencias del proyecto"

Push-Location $APP
try {
    if (Test-Path (Join-Path $APP "package-lock.json")) {
        & npm ci --omit=dev --no-audit --no-fund
    } else {
        & npm install --omit=dev --no-audit --no-fund
    }
    if ($LASTEXITCODE -ne 0) { Morir "npm fallo. Revisa el mensaje de arriba." }
} finally {
    Pop-Location
}
Verde "Dependencias instaladas."

# ------------------------------------------------------------------
Paso "Registrando el servicio"

$carpetaLogs = Join-Path $APP "logs"
if (-not (Test-Path $carpetaLogs)) { New-Item -ItemType Directory -Path $carpetaLogs | Out-Null }

# Envoltura en cmd para poder mandar la salida a un archivo: la tarea
# programada por si sola no redirige stdout.
$wrapper = Join-Path $APP "windows\ejecutar.cmd"
if (-not (Test-Path $wrapper)) { Morir "Falta windows\ejecutar.cmd" }

$anterior = Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
if ($anterior) {
    Write-Host "Ya existia la tarea, se vuelve a crear..."
    Stop-ScheduledTask  -TaskName $TAREA -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false
}

# Se apunta directo al .cmd en vez de pasarlo como argumento de cmd.exe:
# el anidado de comillas con rutas que llevan espacios es una fuente clasica
# de tareas que se registran bien pero nunca arrancan.
$accion = New-ScheduledTaskAction -Execute $wrapper -WorkingDirectory $APP

$disparador = New-ScheduledTaskTrigger -AtStartup

# SYSTEM para que arranque sin que nadie inicie sesion.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$opciones = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TAREA -Action $accion -Trigger $disparador `
    -Principal $principal -Settings $opciones `
    -Description "Konekt Sales - CRM y generador de propuestas" | Out-Null

Verde "Tarea '$TAREA' registrada: arranca sola al prender la PC."

# Guardar la ruta de node para el wrapper, por si SYSTEM no la tiene en PATH.
EscribirTexto -Ruta (Join-Path $APP "windows\node-ruta.txt") -Texto $nodeExe

Start-ScheduledTask -TaskName $TAREA
Start-Sleep -Seconds 6

# ------------------------------------------------------------------
Paso "Firewall"

$reglaExiste = Get-NetFirewallRule -DisplayName $REGLA_FW -ErrorAction SilentlyContinue
if ($reglaExiste) {
    Verde "La regla del firewall ya existe."
} else {
    $r = Read-Host "Abro el puerto $PUERTO para la red local? [s/N]"
    if ($r -match '^[SsYy]') {
        New-NetFirewallRule -DisplayName $REGLA_FW -Direction Inbound -Protocol TCP `
            -LocalPort $PUERTO -Action Allow -Profile Private,Domain | Out-Null
        Verde "Puerto $PUERTO abierto solo para redes privadas y de dominio."
        Amaril "No se abrio para redes publicas, a proposito."
    } else {
        Amaril "Firewall sin tocar: solo se podra entrar desde esta misma PC."
    }
}

# ------------------------------------------------------------------
Paso "Comprobacion"

$salud = $null
try {
    $salud = Invoke-RestMethod -Uri "http://127.0.0.1:$PUERTO/api/health" -TimeoutSec 8
} catch {
    $salud = $null
}

Write-Host ""
if ($salud -and $salud.ok) {
    Verde "==============================================="
    Verde "  Konekt Sales quedo instalado y corriendo."
    Verde "==============================================="
} elseif ($salud) {
    Amaril "El servicio corre, pero falta configuracion:"
    Amaril ("  Supabase: {0}   Anthropic: {1}" -f $salud.supabase, $salud.anthropic)
    Amaril "Edita $rutaEnv y luego:  Restart-ScheduledTask -TaskName $TAREA"
} else {
    Rojo "El servicio no respondio."
    Rojo "Revisa el log:  Get-Content '$carpetaLogs\konekt-sales.log' -Tail 40 -Encoding UTF8"
    exit 1
}

$ips = Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
       Select-Object -ExpandProperty IPAddress

Write-Host ""
Write-Host "  Desde esta PC:      http://localhost:$PUERTO"
foreach ($ip in $ips) {
    Write-Host "  Desde la red local: http://${ip}:$PUERTO"
}

Write-Host ""
Write-Host "  Ver el log:   Get-Content '$carpetaLogs\konekt-sales.log' -Tail 40 -Wait -Encoding UTF8"
Write-Host "  Reiniciar:    Restart-ScheduledTask -TaskName $TAREA"
Write-Host "  Detener:      Stop-ScheduledTask -TaskName $TAREA"
Write-Host "  Actualizar:   powershell -ExecutionPolicy Bypass -File .\windows\actualizar.ps1"
Write-Host "  Desinstalar:  powershell -ExecutionPolicy Bypass -File .\windows\desinstalar.ps1"
Write-Host ""
Amaril "  Esto va por HTTP sin cifrar: usalo solo en la red interna."
Amaril "  Antes de dar acceso al equipo, corre la prueba de RLS de supabase\README.md."
Write-Host ""

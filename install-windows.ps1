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

# PowerShell 5.1 puede negociar TLS 1.0 por omision y nodejs.org lo rechaza.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Buscar-Node {
    # Se relee el PATH del registro: un instalador que acaba de correr no
    # actualiza el PATH de esta sesion.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Se comprueba la capacidad, no el numero de version: lo que hace falta es que
# exista node:sqlite sin bandera, y eso depende del parche, no solo del mayor.
function SirveEsteNode {
    param([string]$Exe)
    try {
        & $Exe -e "require('node:sqlite')" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$nodeExe = Buscar-Node

if ($nodeExe -and (SirveEsteNode $nodeExe)) {
    Verde "Node ya instalado: $(& $nodeExe -v)  (node:sqlite disponible)"
} else {
    if ($nodeExe) {
        Amaril "El Node instalado ($(& $nodeExe -v)) no trae node:sqlite."
        Amaril "Hace falta Node 22.13 o superior. Se instalara uno nuevo."
    }
    $nodeExe = $null

    # --- Intento 1: winget, forzando el origen 'winget' -------------------
    # Sin --source, winget tambien intenta refrescar el origen 'msstore', que
    # pide aceptar contratos y suele tronar con 0x80190194 (404).
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Intentando con winget..."
        try {
            winget install --id OpenJS.NodeJS.LTS --source winget --silent `
                   --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } catch { }
        $nodeExe = Buscar-Node
        if ($nodeExe -and -not (SirveEsteNode $nodeExe)) { $nodeExe = $null }
        if (-not $nodeExe) { Amaril "winget no pudo. Bajo el instalador oficial." }
    }

    # --- Intento 2: MSI directo de nodejs.org ------------------------------
    # No depende de winget ni de la Microsoft Store.
    if (-not $nodeExe) {
        try {
            Write-Host "Consultando cual es la version LTS..."
            $indice = Invoke-RestMethod "https://nodejs.org/dist/index.json" -TimeoutSec 30 -UseBasicParsing
            $lts = $indice | Where-Object { $_.lts } | Select-Object -First 1
            if (-not $lts) { throw "no se pudo leer el listado de versiones" }

            $arch = "x86"
            if ([Environment]::Is64BitOperatingSystem) { $arch = "x64" }

            $url = "https://nodejs.org/dist/$($lts.version)/node-$($lts.version)-$arch.msi"
            $msi = Join-Path $env:TEMP "node-$($lts.version)-$arch.msi"

            Write-Host "Bajando Node $($lts.version) $arch (unos 30 MB)..."
            # Sin esto, Invoke-WebRequest pinta una barra de progreso que en
            # PowerShell 5.1 hace la descarga muchas veces mas lenta.
            $progresoPrevio = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $url -OutFile $msi -TimeoutSec 900 -UseBasicParsing
            $ProgressPreference = $progresoPrevio

            Write-Host "Instalando..."
            $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
            # 3010 = instalado, pide reinicio. Para Node no hace falta.
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                Amaril "msiexec termino con codigo $($proc.ExitCode)."
            }
            Remove-Item $msi -Force -ErrorAction SilentlyContinue
            $nodeExe = Buscar-Node
            if ($nodeExe -and -not (SirveEsteNode $nodeExe)) { $nodeExe = $null }
        } catch {
            Amaril "Fallo la descarga directa: $_"
        }
    }

    if (-not $nodeExe) {
        Write-Host ""
        Rojo "No se pudo instalar Node automaticamente."
        Rojo ""
        Rojo "Hazlo a mano, son dos minutos:"
        Rojo "  1. Baja el instalador LTS de https://nodejs.org (version 22.13 o superior)"
        Rojo "  2. Instalalo dando Siguiente a todo"
        Rojo "  3. Cierra esta ventana y abre otra como administrador"
        Rojo "  4. Vuelve a correr install-windows.ps1"
        exit 1
    }
    Verde "Node instalado: $(& $nodeExe -v)"
}

# La tarea programada corre como SYSTEM, que tiene otro PATH: hay que guardar
# la ruta absoluta del ejecutable.
Verde "Ruta de node: $nodeExe"

# ------------------------------------------------------------------
Paso "Configuracion (.env)"

$rutaEnv = Join-Path $APP ".env"

if (Test-Path $rutaEnv) {
    Verde "Ya existe un .env. No lo toco."
} else {
    $plantilla = Join-Path $APP ".env.example"
    if (-not (Test-Path $plantilla)) { Morir "Falta .env.example" }

    Write-Host "Los datos se guardan en una base local (datoskonekt.db)."
    Write-Host "Lo unico que hay que configurar es la llave de Anthropic, y solo"
    Write-Host "sirve para los dos botones de IA del generador. Puedes dejarla vacia."
    Write-Host ""
    $vAnt = Read-Host "  ANTHROPIC_API_KEY "

    $txt = Get-Content $plantilla -Raw

    if ($vAnt) { $txt = $txt -replace '(?m)^ANTHROPIC_API_KEY=.*', ("ANTHROPIC_API_KEY=" + $vAnt) }

    $txt = $txt -replace '(?m)^NODE_ENV=.*', 'NODE_ENV=production'
    # Sin login: se entra directo, sin contrasena. Ver .env.example.
    $txt = $txt -replace '(?m)^SIN_LOGIN=.*', 'SIN_LOGIN=1'
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
Paso "Primer usuario"

$cliUsuario = Join-Path $APP "scripts\usuario.js"
$sinLogin = (Get-Content $rutaEnv -Raw) -match "(?m)^SIN_LOGIN=1"
$hayUsuarios = $sinLogin
try {
    $salida = & $nodeExe $cliUsuario listar 2>&1 | Out-String
    $hayUsuarios = -not ($salida -match "No hay usuarios")
} catch { }

if ($sinLogin) {
    Verde "SIN_LOGIN activo: se entra sin contrasena, no hace falta crear usuarios."
} elseif ($hayUsuarios) {
    Verde "Ya hay usuarios dados de alta."
} else {
    Amaril "La base esta vacia: sin usuarios nadie puede entrar."
    $r = Read-Host "Creo el primer administrador ahora? [S/n]"
    if ($r -notmatch '^[Nn]') {
        $correo = Read-Host "  Correo"
        $quien  = Read-Host "  Nombre"
        Push-Location $APP
        try { & $nodeExe $cliUsuario crear $correo $quien admin } finally { Pop-Location }
    } else {
        Amaril 'Hazlo despues con:  npm run usuario -- crear tu@correo.mx "Tu Nombre" admin'
    }
}

# ------------------------------------------------------------------
Paso "Respaldo automatico"

# Al no usar una base en la nube, los respaldos son responsabilidad de esta
# maquina. Sin esto, si el disco muere se pierde la cartera completa.
$TAREA_RESP = "KonektSalesRespaldo"
$vieja = Get-ScheduledTask -TaskName $TAREA_RESP -ErrorAction SilentlyContinue
if ($vieja) { Unregister-ScheduledTask -TaskName $TAREA_RESP -Confirm:$false }

$accionResp = New-ScheduledTaskAction -Execute $nodeExe `
    -Argument (Join-Path "scripts" "respaldar.js") -WorkingDirectory $APP
$dispResp   = New-ScheduledTaskTrigger -Daily -At 11pm
$opcResp    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TAREA_RESP -Action $accionResp -Trigger $dispResp `
    -Principal $principal -Settings $opcResp `
    -Description "Konekt Sales - respaldo diario de la base" | Out-Null

Verde "Respaldo diario a las 11 pm, en la carpeta respaldos (se guardan 30)."
Amaril "Eso protege del borrado accidental, NO de que muera el disco."
Amaril "Copia la carpeta respaldos a otro lado (USB, nube, otra PC) cada cierto tiempo."

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
    Amaril ("  Base de datos: {0}   Anthropic: {1}" -f $salud.baseDatos, $salud.anthropic)
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
Amaril "  Comprueba que un vendedor no vea la cartera de otro antes de dar accesos."
Write-Host ""

# Desplegar Konekt Sales

La aplicación es un solo proceso de Node: sirve la interfaz, la API del CRM y
dos endpoints de IA. **Los datos viven en una base SQLite local**, un solo
archivo en `datos/konekt.db`. No hay servicio de base de datos que instalar ni
nada en la nube.

> **Eso significa que los respaldos son responsabilidad del servidor.** Si ese
> disco muere sin copias, se pierde la cartera completa. Los instaladores
> programan un respaldo diario, pero hay que sacar esas copias a otro lado.

> **Y viene sin login.** El `.env` trae `SIN_LOGIN=1`: se abre la página y ya
> estás dentro, sin contraseña. Sirve para una red interna cerrada. **No lo
> publiques a internet así**: cualquiera con la URL entraría y podría borrar la
> cartera. Para activar el login, quita esa línea del `.env`, reinicia y crea
> usuarios con `npm run usuario`.

Cuatro caminos. Los tres de Linux terminan igual: la app escuchando en
`127.0.0.1:3000` y nginx enfrente con HTTPS. El de Windows es un puente para
arrancar ya en la red interna, sin cifrado.

| Camino                    | Cuándo conviene                                                     |
| ------------------------- | ------------------------------------------------------------------- |
| **`install-windows.ps1`** | Windows 10/11. Para arrancar hoy en la red interna. Sin HTTPS.      |
| **`install.sh`**          | Debian o Ubuntu, un comando. **El destino final.**                  |
| **Docker**                | Si prefieres contenedores, o el servidor no es Debian ni Ubuntu.    |
| **Node + systemd**        | Paso a paso a mano, para ver qué hace cada cosa.                    |

---

## Instalación en un comando

En un servidor **Debian o Ubuntu recién instalado**, esto hace todo: instala
Node, nginx y certbot, crea el usuario del servicio, te pregunta las tres llaves
del `.env`, registra el servicio en systemd, configura el dominio y levanta el
firewall.

```bash
sudo git clone https://github.com/Konekt-ai/Konekt-sales.git /opt/konekt-sales
cd /opt/konekt-sales
sudo ./install.sh
```

Te va a preguntar la llave de Anthropic y el dominio. La base se crea sola y,
como viene sin login, no hace falta dar de alta a nadie.

Se puede volver a correr sin miedo: no pisa un `.env` que ya exista y no duplica
nada.

**Para actualizar**, más adelante:

```bash
cd /opt/konekt-sales
sudo ./deploy/actualizar.sh
```

Trae los cambios, reinstala dependencias solo si cambiaron, reinicia y comprueba
la salud. **Si el servicio no responde bien después de actualizar, regresa solo
a la versión anterior.**

> El resto de este documento explica los mismos pasos a mano, por si prefieres
> ir viendo qué hace cada uno, o si tu servidor no es Debian ni Ubuntu.

---

## Windows 10 · como paso intermedio

Sirve para arrancar hoy en la red interna, sin esperar a tener Linux. La
aplicación es la misma; lo único que cambia es cómo se mantiene viva.

Abre **PowerShell como administrador** y:

```powershell
cd C:\konekt-sales
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Instala Node si falta (con winget), instala dependencias, te pregunta las tres
llaves, registra una **tarea programada** que arranca el servicio al prender la
PC y lo revive si se cae, abre el puerto 3000 solo para redes privadas, y al
final te dice la dirección para entrar desde otra máquina de la red.

Se puede volver a correr: no pisa un `.env` que ya exista.

```powershell
# Actualizar
powershell -ExecutionPolicy Bypass -File .\windows\actualizar.ps1

# Ver el log
Get-Content .\logs\konekt-sales.log -Tail 40 -Wait -Encoding UTF8

# Reiniciar / detener
Restart-ScheduledTask -TaskName KonektSales
Stop-ScheduledTask    -TaskName KonektSales
```

### Si falla la instalación de Node

El instalador intenta tres cosas en orden: winget, descarga directa del MSI de
nodejs.org, y si no, te dice cómo hacerlo a mano.

winget falla seguido con `0x80190194` o *"Error al intentar actualizar el
origen"*: es un problema del índice de paquetes de winget, no de tu máquina.
Por eso existe el segundo camino, que no depende de winget ni de la Microsoft
Store.

Si quieres instalarlo por tu cuenta antes de correr el instalador:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$v = (Invoke-RestMethod https://nodejs.org/dist/index.json | Where-Object lts | Select-Object -First 1).version
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest "https://nodejs.org/dist/$v/node-$v-x64.msi" -OutFile "$env:TEMP
ode.msi" -UseBasicParsing
Start-Process msiexec -ArgumentList "/i `"$env:TEMP
ode.msi`" /qn /norestart" -Wait
```

Cierra la ventana, abre otra como administrador y vuelve a correr el
instalador. El `$ProgressPreference` no es adorno: sin él, PowerShell 5.1
pinta una barra de progreso que hace la descarga varias veces más lenta.

---

## Verlo desde otras PCs con Tailscale

Es la mejor forma de dar acceso al equipo sin publicar nada a internet: red
privada cifrada, sin abrir puertos en el módem y sin depender de que el ISP dé
IP fija.

**En la PC servidor**, una vez instalada la aplicación:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\tailscale.ps1
```

Comprueba que Tailscale esté instalado y conectado, que la aplicación responda,
y te deja elegir entre dos formas de publicarla:

| | Cómo se ve | Cifrado | Firewall |
| --- | --- | --- | --- |
| **`tailscale serve`** (recomendado) | `https://esta-pc.tu-tailnet.ts.net` | HTTPS con certificado válido | No hay que tocarlo |
| Acceso directo | `http://100.x.y.z:3000` | Solo el de WireGuard | Abre el puerto al rango del tailnet |

Las dos van cifradas de extremo a extremo por WireGuard, que es lo que hace
Tailscale por debajo. La diferencia es que con `tailscale serve` además el
navegador ve un certificado válido y no marca el sitio como inseguro.

**En cada PC del equipo:** instalar Tailscale, iniciar sesión con la misma
cuenta de Konekt, y abrir la dirección. Nada más.

> **Nunca uses `tailscale funnel`.** Se parece a `serve` pero publica el sitio
> a **internet entero**, y esta aplicación entra sin contraseña.

### Si `tailscale serve` falla

Casi siempre es porque faltan dos cosas en el panel de Tailscale
(<https://login.tailscale.com/admin/dns>):

- **MagicDNS** → Enable
- **HTTPS Certificates** → Enable

Actívalas y vuelve a correr el script.

### Sobre el firewall

El instalador crea **dos reglas** distintas:

- Una para la red local, solo en perfiles privado y de dominio.
- Otra para Tailscale, limitada a `100.64.0.0/10` pero en **todos** los
  perfiles. Va aparte a propósito: Windows suele clasificar el adaptador de
  Tailscale como red *pública*, así que la primera regla no lo cubriría y el
  acceso por VPN fallaría sin explicación aparente. Lo que acota el riesgo no
  es el perfil sino el rango: solo los equipos del tailnet tienen una dirección
  ahí.

### Si más adelante activas el login

Con `tailscale serve` el sitio va por HTTPS, así que conviene poner
`COOKIE_SEGURA=1` en el `.env` para que la cookie de sesión se marque como
`Secure`.

### Qué es distinto respecto a Linux

Vale la pena tenerlo claro, porque son las razones para no quedarse aquí:

| | Windows (ahora) | Linux (después) |
| --- | --- | --- |
| Se mantiene vivo con | Tarea programada | systemd |
| Corre como | `SYSTEM` | usuario `konekt`, sin shell ni privilegios |
| Cifrado | **No: HTTP plano** | HTTPS con certificado gratuito |
| Expuesto a internet | No conviene | Sí, con nginx enfrente |

**Sobre el HTTP sin cifrar:** como viene sin login, no hay contraseñas viajando
por la red — pero tampoco hay nada que impida entrar. En una red interna cerrada
es un riesgo acotado; **para internet no lo es**. Cuando lo expongas: HTTPS,
quitar `SIN_LOGIN` y poner `COOKIE_SEGURA=1` en el `.env`.

Por lo mismo, el instalador abre el puerto solo para perfiles de red **privada y
de dominio**, nunca para redes públicas.

### Cuando muevas todo a Linux

En la máquina Windows, para que deje de levantar el servicio sola:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\desinstalar.ps1
```

Quita las tareas programadas y la regla del firewall. No toca el `.env`, ni el
proyecto, ni la base.

**Los datos sí se migran ahora**, y es fácil: son un archivo.

```powershell
# En Windows, antes de apagar el servicio
npm run respaldar
```

Copia `datos\konekt.db` (o el respaldo más reciente) al servidor Linux, ponlo en
`/opt/konekt-sales/datos/konekt.db`, ajusta el dueño con
`chown konekt:konekt` y arranca. Se lleva todo: usuarios, contraseñas,
prospectos, documentos y plantillas.

## Antes de empezar

Necesitas:

- Un VPS con Linux (Ubuntu 22.04 o 24.04 va bien). Con 1 GB de RAM alcanza.
- Un dominio o subdominio apuntando por DNS a la IP del servidor
  (por ejemplo `ventas.konekt.mx` → registro **A** → la IP).
- Tu `ANTHROPIC_API_KEY` (opcional: solo para los botones de IA del generador).

> **HTTPS no es opcional.** Sin él, las contraseñas y los tokens de sesión
> viajan en claro. Los pasos de abajo lo incluyen y es gratis con Let's Encrypt.

---

## Paso 1 · Subir el código

En tu máquina, sube el repositorio a GitHub (privado) y en el servidor:

```bash
sudo mkdir -p /opt/konekt-sales
sudo chown $USER:$USER /opt/konekt-sales
git clone https://github.com/tu-usuario/konekt-sales.git /opt/konekt-sales
cd /opt/konekt-sales
```

Si prefieres no usar Git, copia la carpeta con `scp` desde tu máquina —
**sin `node_modules`**, que se instala allá:

```bash
scp -r ./Konekt-sales usuario@IP:/opt/konekt-sales
```

## Paso 2 · Configurar el .env

```bash
cp .env.example .env
nano .env
chmod 600 .env
```

Llena lo que importa:

```ini
ANTHROPIC_API_KEY=sk-ant-...
NODE_ENV=production
TRUST_PROXY=1
```

`TRUST_PROXY=1` es importante: sin él, el servidor ve la IP de nginx en vez de
la del usuario y el límite de uso estrangula a todo el equipo como si fuera una
sola persona.

> El `.env` está en `.gitignore` y en `.dockerignore`. Nunca se sube al
> repositorio ni se hornea en la imagen de Docker.

---

## Camino A · Docker (recomendado)

Instalar Docker, si no lo tienes:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # cierra sesión y vuelve a entrar
```

Levantar:

```bash
cd /opt/konekt-sales
docker compose up -d --build
```

Comprobar:

```bash
docker compose ps          # debe decir "healthy" tras unos segundos
curl localhost:3000/api/health
docker compose logs -f
```

Actualizar cuando haya cambios:

```bash
cd /opt/konekt-sales
git pull
docker compose up -d --build
```

`restart: unless-stopped` hace que el contenedor vuelva solo si truena o si
reinicias el servidor. Sigue con el **Paso 3**.

---

## Camino B · Node + systemd

Instalar Node 22:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Crear un usuario sin privilegios para correr la app:

```bash
sudo useradd --system --home /opt/konekt-sales --shell /usr/sbin/nologin konekt
sudo chown -R konekt:konekt /opt/konekt-sales
```

Instalar dependencias y registrar el servicio:

```bash
cd /opt/konekt-sales
sudo -u konekt npm ci --omit=dev

sudo cp deploy/konekt-sales.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now konekt-sales
```

Comprobar:

```bash
sudo systemctl status konekt-sales
curl localhost:3000/api/health
sudo journalctl -u konekt-sales -f
```

Actualizar cuando haya cambios:

```bash
cd /opt/konekt-sales
sudo -u konekt git pull
sudo -u konekt npm ci --omit=dev
sudo systemctl restart konekt-sales
```

> Verifica la ruta de node con `which node`. Si no es `/usr/bin/node`, ajusta
> `ExecStart` en el archivo del servicio.

---

## Paso 3 · nginx y HTTPS

Vale para los dos caminos.

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx

sudo cp deploy/nginx.conf /etc/nginx/sites-available/konekt-sales
sudo nano /etc/nginx/sites-available/konekt-sales   # cambia ventas.konekt.mx por tu dominio
sudo ln -s /etc/nginx/sites-available/konekt-sales /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t && sudo systemctl reload nginx
```

Certificado (el dominio ya debe apuntar al servidor):

```bash
sudo certbot --nginx -d ventas.konekt.mx
```

Certbot instala el certificado y deja la renovación automática. Comprobar que
renovará bien:

```bash
sudo certbot renew --dry-run
```

## Paso 4 · Cerrar el firewall

Solo SSH y web. El puerto 3000 **no** se abre: nginx llega por dentro.

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
sudo ufw status
```

---

## Paso 5 · Probar de verdad

En este orden. Si uno falla, no sigas al siguiente.

1. **Salud** — `curl https://ventas.konekt.mx/api/health`
   Debe responder `{"ok":true,...}`. Si dice `ok:false`, falta algo en el `.env`.

2. **Carga** — abre el dominio en el navegador. Debe salir la pantalla de login,
   no la de configuración. Si sale la de configuración, `SUPABASE_URL` o
   `SUPABASE_ANON_KEY` no están llegando.

3. **Sesión** — entra con tu usuario. Debe aparecer tu nombre y rol abajo a la
   izquierda.

4. **Escritura** — registra un prospecto, recarga la página. Debe seguir ahí.

5. **Acceso** — comprueba en qué modo quedó:
   `curl https://ventas.konekt.mx/api/health` trae `"sinLogin":true` o `false`.
   Si va a estar expuesto a internet **tiene que ser `false`**; quita
   `SIN_LOGIN` del `.env`, reinicia y crea usuarios con `npm run usuario`.

6. **IA** — abre el generador, pega un texto y dale *Analizar con IA*.

7. **Endpoint protegido** — desde tu máquina, sin sesión:

   ```bash
   curl -X POST https://ventas.konekt.mx/api/extract \
        -H "Content-Type: application/json" -d '{"texto":"prueba"}'
   ```

   Debe responder **401** `{"error":"Falta iniciar sesión."}`. Si responde otra
   cosa, cualquiera con la URL puede gastar tu presupuesto de Anthropic —
   detente y revisa.

8. **Reinicio** — `sudo reboot`. Al volver, el sitio debe estar arriba solo.

---

## Operación

**Ver logs**

```bash
docker compose logs -f --tail=100          # Docker
sudo journalctl -u konekt-sales -f         # systemd
```

**Reiniciar**

```bash
docker compose restart                     # Docker
sudo systemctl restart konekt-sales        # systemd
```

**Cambiar una variable del .env** — edita el archivo y reinicia. Las variables
se leen al arrancar.

**Respaldos** — esto ya no es opcional. La instalación deja un respaldo diario a
las 11 pm en `respaldos/`, con rotación de 30. Se puede correr a mano:

```bash
npm run respaldar
npm run respaldar -- /media/usb/konekt   # a otro disco
```

Usa `VACUUM INTO`, no una copia del archivo: eso da una copia consistente aunque
alguien esté usando la app. Copiar el `.db` a mano mientras hay escrituras puede
dejarlo corrupto.

**Saca esas copias del servidor.** El respaldo local protege de un borrado
accidental, no de que se queme el disco. Un USB, otra PC o un almacenamiento en
red, con la periodicidad que aguante el negocio.

**Rotar la llave de Anthropic** — genera una nueva en la consola, cámbiala en el
`.env`, reinicia, y hasta entonces revoca la vieja.

---

## Si algo falla

| Síntoma                                     | Causa más probable                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| Sale la pantalla de configuración           | Faltan `SUPABASE_URL` / `SUPABASE_ANON_KEY` en el `.env`, o no reiniciaste |
| `502 Bad Gateway`                           | La app no está corriendo. Revisa los logs                                  |
| Login dice "No se pudo conectar"            | El servicio no está corriendo. Revisa los logs                            |
| Todo el equipo topa el límite de peticiones | Falta `TRUST_PROXY=1` en el `.env`                                         |
| La IA responde 401                          | La sesión expiró. Salir y volver a entrar                                  |
| La IA responde 503                          | Falta `ANTHROPIC_API_KEY` en el `.env`                                     |
| "La respuesta se cortó por límite de tokens"| El texto de entrada es larguísimo. Recórtalo                               |
| El certificado no renueva                   | El puerto 80 quedó cerrado. `sudo ufw allow 'Nginx Full'`                  |

---

## Lo que este despliegue todavía no cubre

Para que no haya sorpresas:

- **El PDF sigue saliendo del diálogo de impresión del navegador.** Funciona,
  pero depende del navegador de cada quien y el archivo no se guarda. El render
  en servidor con Chromium headless es el siguiente paso grande.
- **Konekt AI en la ficha del prospecto** todavía no genera nada: muestra un
  estado vacío.
- **Editar un prospecto ya creado** y **agendar tareas** desde la interfaz no
  están; por ahora se ajusta directamente en la base.
- **Una sola instancia.** El límite de uso vive en memoria y SQLite es un
  archivo local: esto corre en una máquina, no en varias a la vez.
- **Sin monitoreo externo.** `/api/health` está listo para que le apuntes algo
  (UptimeRobot, Healthchecks.io o lo que uses), pero no hay nada configurado.

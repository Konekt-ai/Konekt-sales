# Desplegar Konekt Sales

La aplicación es un solo proceso de Node que sirve archivos estáticos y dos
endpoints de IA. **Todos los datos viven en Supabase**, así que el servidor no
guarda nada en disco: se puede reiniciar, mover o reconstruir sin perder
información, y no necesita respaldos propios.

Hay tres caminos. Todos terminan igual: la app escuchando en `127.0.0.1:3000`
y nginx enfrente con HTTPS.

| Camino             | Cuándo conviene                                                          |
| ------------------ | ------------------------------------------------------------------------ |
| **`install.sh`**   | Debian o Ubuntu. Un comando y queda todo listo. **Empieza por aquí.**     |
| **Docker**         | Si prefieres contenedores, o el servidor no es Debian ni Ubuntu.         |
| **Node + systemd** | Paso a paso a mano, para ver qué hace cada cosa o ajustar algo.          |

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

Te va a preguntar cuatro cosas: las tres llaves (`SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `ANTHROPIC_API_KEY`) y el dominio. Puedes dejarlas vacías y
editar `/opt/konekt-sales/.env` después.

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

## Antes de empezar

Necesitas:

- Un VPS con Linux (Ubuntu 22.04 o 24.04 va bien). Con 1 GB de RAM alcanza.
- Un dominio o subdominio apuntando por DNS a la IP del servidor
  (por ejemplo `ventas.konekt.mx` → registro **A** → la IP).
- El proyecto de Supabase ya creado y con `supabase/schema.sql` ejecutado.
  Si no, ve primero a [`supabase/README.md`](supabase/README.md).
- Tu `ANTHROPIC_API_KEY`.

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

Llena los cinco valores que importan:

```ini
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOi...
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

5. **RLS** — la prueba de cinco pasos al final de
   [`supabase/README.md`](supabase/README.md). **No des de alta al equipo sin
   hacerla:** verifica que un vendedor no alcance a ver la cartera de otro.

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

**Respaldos** — el servidor no guarda nada; todo está en Supabase. Los respaldos
se configuran del lado de Supabase (Database → Backups). Del servidor, lo único
irreemplazable es el `.env`: guárdalo en un gestor de contraseñas.

**Rotar la llave de Anthropic** — genera una nueva en la consola, cámbiala en el
`.env`, reinicia, y hasta entonces revoca la vieja.

---

## Si algo falla

| Síntoma                                     | Causa más probable                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| Sale la pantalla de configuración           | Faltan `SUPABASE_URL` / `SUPABASE_ANON_KEY` en el `.env`, o no reiniciaste |
| `502 Bad Gateway`                           | La app no está corriendo. Revisa los logs                                  |
| Login dice "No se pudo conectar"            | `SUPABASE_URL` mal escrita, o el proyecto de Supabase está pausado         |
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
  están; por ahora se hace desde el editor de tablas de Supabase.
- **Una sola instancia.** El límite de uso vive en memoria, así que si algún día
  corres dos réplicas, cada una llevará su propia cuenta.
- **Sin monitoreo externo.** `/api/health` está listo para que le apuntes algo
  (UptimeRobot, Healthchecks.io o lo que uses), pero no hay nada configurado.

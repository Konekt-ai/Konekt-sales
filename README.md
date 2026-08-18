# Konekt Sales

Plataforma comercial de Konekt: CRM + generador de propuestas y cotizaciones con IA.
La API key vive solo en el servidor; el navegador nunca la ve.

> **Estado: en desarrollo.** El diseño y los flujos están terminados. Los datos
> viven en una base **SQLite local**, en un solo archivo dentro de `datos/`: no
> depende de ningún servicio en línea. Falta la generación robusta de PDF y la
> capa de IA en la ficha del prospecto.

## Correr en local

1. Instalar [Node.js 18 o superior](https://nodejs.org)
2. Instalar dependencias:
   ```bash
   npm install
   ```
3. Copiar `.env.example` como `.env`. Lo único que hay que llenar es la llave
   de Anthropic, y solo sirve para los dos botones de IA del generador:
   ```ini
   ANTHROPIC_API_KEY=sk-ant-...
   ```
   La base de datos se crea sola en `datos/konekt.db` al arrancar.
4. Crear el primer usuario:
   ```bash
   npm run usuario -- crear tu@correo.mx "Tu Nombre" admin
   ```
5. Arrancar:
   ```bash
   npm start
   ```
   o, con recarga automática al editar:
   ```bash
   npm run dev
   ```
6. Abrir <http://localhost:3000>

Para ver el estado: <http://localhost:3000/api/health>

## Estructura

```text
server.js                       backend Express. Único que habla con Anthropic.
package.json                    dependencias y scripts
.env.example                    plantilla de configuración (copiar como .env)
install-windows.ps1             instalador para Windows 10/11
install.sh                      instalador para Debian/Ubuntu: un solo comando
DEPLOY.md                       cómo subirlo a un VPS, paso a paso
Dockerfile                      imagen de producción
docker-compose.yml              camino con Docker
windows/
  ejecutar.cmd                  lanzador de la tarea programada, con log
  actualizar.ps1                git pull + reinicio, con vuelta atrás si falla
  desinstalar.ps1               quita la tarea y el firewall al migrar a Linux
deploy/
  actualizar.sh                 git pull + reinicio, con vuelta atrás si falla
  konekt-sales.service          camino sin Docker: servicio de systemd
  nginx.conf                    proxy inverso con HTTPS (para ambos caminos)
db/
  esquema.sql                   tablas, índices y disparadores (SQLite)
  index.js                      conexión y ayudas
  auth.js                       usuarios, contraseñas y sesiones
rutas/
  api.js                        toda la API del CRM. Aquí vive el control de acceso.
scripts/
  usuario.js                    alta y administración de usuarios
  respaldar.js                  respaldo de la base, con rotación
datos/                          la base: konekt.db  (no se sube a git)
respaldos/                      copias con fecha    (no se suben a git)
public/
  konekt-sales.html             LA aplicación: CRM + generador + hojas A4
  konekt-db.js                  capa de datos: lo único que llama a la API
  assets/konekt-logo.png        logo (antes iba incrustado 5 veces en el HTML)
_entrega-original/              archivos tal como llegaron, sin modificar
HANDOFF.md                      documento de entrega original
```

Cómo fluye un dato:

```text
navegador  →  konekt-db.js  →  /api/*  →  rutas/api.js  →  db/  →  datos/konekt.db
```

El navegador nunca toca la base. **El control de acceso vive en `rutas/api.js`**:
cada consulta de prospectos se filtra por `vendedor_id` salvo que el usuario sea
gerente o admin. Antes lo imponía Postgres con RLS y era imposible saltárselo;
ahora es código, así que cualquier consulta nueva tiene que respetar ese filtro.

## Endpoints

| Método | Ruta                | Sesión | Qué hace                                              |
| ------ | ------------------- | ------ | ----------------------------------------------------- |
| `POST` | `/api/extract`      | Sí     | Texto libre → datos estructurados del proyecto        |
| `POST` | `/api/redactar`     | Sí     | Datos confirmados → contenido redactado de propuesta  |
| `GET`  | `/api/health`       | No     | Diagnóstico para Docker, systemd y monitoreo          |

Además hay un CRUD completo bajo `/api/` (prospectos, actividades, documentos,
tareas, calendario, plantillas y usuarios), todo detrás de sesión.

La sesión viaja en una cookie **httpOnly** con **SameSite=Strict**: el JavaScript
de la página no puede leerla, así que un XSS no se lleva la sesión, y no viaja
desde otros sitios, lo que corta el CSRF.

## Desplegar

**En Windows 10/11** (PowerShell como administrador), para arrancar ya en la red
interna:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Instala Node si falta, pregunta las llaves, registra una tarea programada que
levanta el servicio al prender la PC, y abre el puerto solo para redes privadas.
Va por HTTP sin cifrar: sirve para la red interna, no para internet.

**En un servidor Debian o Ubuntu** recién instalado:

```bash
sudo git clone https://github.com/Konekt-ai/Konekt-sales.git /opt/konekt-sales
cd /opt/konekt-sales
sudo ./install.sh
```

Instala Node, nginx y certbot, crea el usuario del servicio, pregunta las llaves,
registra el servicio y levanta el firewall. Para actualizar después:
`sudo ./deploy/actualizar.sh`.

El detalle completo, los otros caminos (Docker o paso a paso) y las pruebas de
verificación están en [`DEPLOY.md`](DEPLOY.md).

## Advertencias para esta etapa

- **No subas el `.env` a Git.** Ya está en `.gitignore`; verifícalo antes de
  hacer push a un repositorio remoto.
- **Los respaldos ahora son tuyos.** Toda la cartera vive en `datos/konekt.db`.
  El instalador programa un respaldo diario a `respaldos/`, pero eso protege del
  borrado accidental, **no de que muera el disco**: copia esa carpeta a otro lado.
- **Comprueba el aislamiento antes de dar accesos.** Entra con dos usuarios
  distintos y verifica que un vendedor no vea la cartera del otro.
- La exportación a PDF sigue usando el diálogo de impresión del navegador.
  Funciona para demo; para que sea consistente hay que renderizar en servidor.
- La ficha del prospecto aún no genera el análisis de Konekt AI: muestra un
  estado vacío explicando que llega después.
- Editar un prospecto ya creado y agendar tareas desde la interfaz todavía no
  está; por ahora se ajusta directamente en la base.

## Qué falta

| Tema                    | Estado                                                     |
| ----------------------- | ---------------------------------------------------------- |
| Base de datos y sesión  | Listo — SQLite local, alcance por vendedor en la API  |
| Alta y pipeline         | Listo — se crea, se arrastra y persiste                    |
| Editar prospecto        | Pendiente                                                  |
| PDF robusto en servidor | Pendiente — render con Chromium headless, sin tocar diseño |
| Konekt AI en la ficha   | Pendiente — con caché por contenido en `ai_insights`       |
| Integraciones           | Pendiente — Meta Lead Ads, WhatsApp, correo, calendario    |

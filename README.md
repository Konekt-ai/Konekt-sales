# Konekt Sales

Plataforma comercial de Konekt: CRM + generador de propuestas y cotizaciones con IA.
La API key vive solo en el servidor; el navegador nunca la ve.

> **Estado: en desarrollo.** El diseño y los flujos están terminados. Los datos
> del CRM ya no son de demostración: viven en Supabase y persisten. Falta la
> generación robusta de PDF y la capa de IA en la ficha del prospecto.

## Correr en local

1. Instalar [Node.js 18 o superior](https://nodejs.org)
2. Instalar dependencias:
   ```bash
   npm install
   ```
3. **Conectar Supabase** siguiendo [`supabase/README.md`](supabase/README.md).
   Sin esto la aplicación abre en una pantalla que te explica los pasos.
4. Copiar `.env.example` como `.env` y llenar tres valores:
   ```ini
   SUPABASE_URL=https://xxxx.supabase.co
   SUPABASE_ANON_KEY=eyJhbGciOi...
   ANTHROPIC_API_KEY=sk-ant-...
   ```
   El servidor le pasa los dos primeros al navegador y usa el tercero para los
   botones de IA del generador.
5. Arrancar:
   ```bash
   npm start
   ```
   o, con recarga automática al editar:
   ```bash
   npm run dev
   ```
6. Abrir <http://localhost:3000>

Para verificar que la llave de Anthropic se cargó: <http://localhost:3000/api/health>

## Estructura

```text
server.js                       backend Express. Único que habla con Anthropic.
package.json                    dependencias y scripts
.env.example                    plantilla de configuración (copiar como .env)
DEPLOY.md                       cómo subirlo a un VPS, paso a paso
Dockerfile                      imagen de producción
docker-compose.yml              camino con Docker
deploy/
  konekt-sales.service          camino sin Docker: servicio de systemd
  nginx.conf                    proxy inverso con HTTPS (para ambos caminos)
supabase/
  schema.sql                    tablas, disparadores y políticas RLS
  README.md                     cómo conectar Supabase, paso a paso
public/
  konekt-sales.html             LA aplicación: CRM + generador + hojas A4
  konekt-db.js                  capa de datos. Lo único que habla con Supabase.
  konekt-config.example.js      config local opcional (normalmente va en el .env)
  vendor/supabase.js            librería de Supabase, vendorizada (sin CDN)
  assets/konekt-logo.png        logo (antes iba incrustado 5 veces en el HTML)
_entrega-original/              archivos tal como llegaron, sin modificar
HANDOFF.md                      documento de entrega original
```

Dos capas separadas a propósito:

- **`konekt-db.js`** habla con Supabase directo desde el navegador. Los permisos
  los impone Postgres con RLS, no el JavaScript.
- **`server.js`** existe solo para resguardar la llave de Anthropic, y más
  adelante para generar los PDF. No toca la base de datos.

## Endpoints

| Método | Ruta                | Sesión | Qué hace                                              |
| ------ | ------------------- | ------ | ----------------------------------------------------- |
| `POST` | `/api/extract`      | Sí     | Texto libre → datos estructurados del proyecto        |
| `POST` | `/api/redactar`     | Sí     | Datos confirmados → contenido redactado de propuesta  |
| `GET`  | `/api/health`       | No     | Diagnóstico para Docker, systemd y monitoreo          |
| `GET`  | `/konekt-config.js` | No     | Config de Supabase para el navegador, desde el `.env` |

Los que dicen **Sí** exigen la cabecera `Authorization: Bearer <token>` con una
sesión válida de Supabase, y llevan un tope de 40 peticiones por usuario cada 5
minutos. Sin eso, cualquiera con la URL podría gastar el presupuesto de
Anthropic.

## Desplegar

Ver [`DEPLOY.md`](DEPLOY.md). Cubre los dos caminos —Docker o Node con
systemd— más nginx, HTTPS, firewall y las pruebas de verificación.

## Advertencias para esta etapa

- **No subas el `.env` a Git.** Ya está en `.gitignore`; verifícalo antes de
  hacer push a un repositorio remoto.
- **Verifica RLS antes de dar de alta al equipo.** La prueba de cinco pasos está
  al final de [`supabase/README.md`](supabase/README.md). Si un vendedor alcanza
  a ver prospectos ajenos, algo quedó mal configurado.
- La exportación a PDF sigue usando el diálogo de impresión del navegador.
  Funciona para demo; para que sea consistente hay que renderizar en servidor.
- La ficha del prospecto aún no genera el análisis de Konekt AI: muestra un
  estado vacío explicando que llega después.
- Editar un prospecto ya creado y agendar tareas desde la interfaz todavía no
  está: por ahora se hace desde el editor de tablas de Supabase.

## Qué falta

| Tema                    | Estado                                                     |
| ----------------------- | ---------------------------------------------------------- |
| Base de datos y sesión  | Listo — Supabase con RLS por vendedor                      |
| Alta y pipeline         | Listo — se crea, se arrastra y persiste                    |
| Editar prospecto        | Pendiente                                                  |
| PDF robusto en servidor | Pendiente — render con Chromium headless, sin tocar diseño |
| Konekt AI en la ficha   | Pendiente — con caché por contenido en `ai_insights`       |
| Integraciones           | Pendiente — Meta Lead Ads, WhatsApp, correo, calendario    |

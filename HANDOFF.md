# Konekt Sales — Entrega técnica

Plataforma comercial (CRM + generador de propuestas/cotizaciones con IA) en **un solo HTML**,
con un backend mínimo que resguarda la API key. Diseño y flujo terminados; falta conectar datos reales.

---

## 1. Qué se construyó

Una plataforma con barra lateral única: **Dashboard, Mi día, Pipeline, Calendario, Clientes,
Propuestas, Cotizaciones y Panel del admin**. Todo comparte la misma identidad visual de Konekt.

- **Pipeline** tipo kanban con arrastre entre etapas.
- **Ficha de prospecto** con pestañas (Resumen, Oportunidad, Actividad/timeline, Documentos, Pagos)
  y tarjeta **Konekt AI**.
- **Generador** de propuesta y cotización **nativo** (sin iframe), integrado en la misma pantalla,
  con el **diseño aprobado** de Konekt (portada, secciones, impacto, cierre) tal cual.
  Exportación a PDF **básica** (usa la impresión del navegador); su robustez la afinará ingeniería.
- **Clientes** con avance de pagos y **recurrentes**; **Calendario** (mes/semana/día);
  **Panel del admin** con desempeño por vendedor.

## 2. Qué es mockup (solo visual / demo)

- Todos los datos son de demostración (arreglos `leads`, `recurrentes`, `tareas`, `eventos` en el HTML).
- Arrastrar en el pipeline, marcar tareas y "convertir a cliente" funcionan **en memoria**
  (se reinician al recargar).
- Calendario, "Nuevo lead", editar prospecto, registrar actividad: botones de demo.
- La tarjeta **Konekt AI** de cada prospecto muestra datos de ejemplo (no llama a IA todavía).

## 3. Qué ya tiene lógica real

- El **generador**: formulario reactivo, cálculo automático de subtotal, IVA 16%, total y esquema
  de pagos (con montos), cambio de logo del cliente, plantillas guardadas (localStorage),
  vista previa en vivo y exportación a PDF básica (impresión del navegador).

## 4. Qué usa la API de Claude (ya conectado por backend)

En el generador:
- **Analizar con IA** → `POST /api/extract`: convierte texto libre en datos estructurados (sin inventar).
- **Redactar propuesta con IA** → `POST /api/redactar`: escribe reto, solución, módulos y beneficios.

El backend (`server.js`) es el único que habla con Anthropic, usando `ANTHROPIC_API_KEY` del `.env`.
Modelo por defecto: `claude-sonnet-5` (cambiable con `KONEKT_MODEL`).

## 5. Qué debe construir / conectar el ingeniero

- **Base de datos** para leads, clientes, actividades, pagos, documentos y usuarios (hoy son arreglos en el HTML).
- **API propia** (CRUD) para reemplazar esos arreglos y persistir los cambios del kanban, tareas y conversión a cliente.
- **Autenticación** de vendedores y separación por rol (vendedor / admin).
- **Konekt AI real** en la ficha del prospecto (resumen, intención, próxima acción): mismo patrón que ya usa el
  generador — llamar al backend, nunca exponer la key.
- **Integraciones** reales: Meta/Facebook Lead Ads, WhatsApp, correo y calendario.
- **Guardado de documentos** generados (propuestas/cotizaciones) ligados al prospecto.
- **Exportación a PDF robusta** (paginación/tamaños): hoy usa la impresión del navegador; se dejó
  intencionalmente básica para no alterar el diseño aprobado. Conviene resolverla con una
  librería/servicio dedicado (p. ej. render headless a PDF) **sin cambiar el diseño**.
- **Plantillas compartidas**: hoy se guardan en `localStorage` (por navegador). Cambiar la capa `storage`
  del generador por un endpoint de servidor.

## 6. Arquitectura ya preparada para conectar

- La capa de guardado del generador está aislada en un objeto `storage` (fácil de apuntar a un servidor).
- Las llamadas a IA ya pasan por backend (`/api/extract`, `/api/redactar`); replicar el mismo patrón para Konekt AI.
- El estado del generador vive en un solo objeto `state`; el render lo pinta. Sustituir el origen de datos
  (de arreglos a API) no cambia la vista.
- Punto de override opcional: `window.KONEKT_API_BASE` para apuntar el frontend a otro backend.

## 7. Archivos que se envían

```
KONEKT_SALES_HANDOFF/
├── server.js            → backend seguro (Express). Expone /api/extract y /api/redactar. Sirve la app.
├── package.json         → dependencias (express, dotenv).
├── .env.example         → copiar como .env y poner ANTHROPIC_API_KEY.
├── HANDOFF.md           → este documento.
└── public/
    └── konekt-sales.html→ LA plataforma completa (CRM + generador + hojas A4 + PDF), un solo archivo.
```

### Correr
```bash
npm install
cp .env.example .env      # y pega tu ANTHROPIC_API_KEY
npm start                 # abre http://localhost:3000
```

### Importante
- **No** incluyas el archivo `.env` real (con la key) en git ni en entregas.
- Archivos de versiones anteriores que **ya NO se usan** y no hay que enviar:
  `konekt-generador.html` suelto (ahora vive integrado dentro de `konekt-sales.html`) y
  cualquier versión previa del generador. La app es únicamente `public/konekt-sales.html`.

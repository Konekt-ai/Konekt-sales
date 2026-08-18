/**
 * Konekt · Backend seguro para el Generador de propuestas
 * -------------------------------------------------------
 * El frontend (HTML) NUNCA ve la API key. El navegador llama a este
 * servidor, y este servidor es el único que habla con Anthropic usando
 * la variable de entorno ANTHROPIC_API_KEY.
 *
 *   Navegador  ->  /api/extract   ->  Anthropic  ->  JSON estructurado
 *   Navegador  ->  /api/redactar  ->  Anthropic  ->  JSON de redacción
 *
 * Ejecutar:   npm start           (requiere Node 18+)
 * Abrir:      http://localhost:3000
 *
 * Los datos viven en SQLite, en un archivo dentro de datos/. No hay base de
 * datos en línea ni servicio de base de datos que mantener corriendo.
 *
 * El navegador nunca toca la base: habla con /api/* y estas rutas hablan con
 * SQLite. La sesión va en una cookie httpOnly.
 */

require("dotenv").config();
const express = require("express");
const path = require("path");
const db = require("./db");
const auth = require("./db/auth");
const api = require("./rutas/api");

const app = express();

const PORT = Number(process.env.PORT) || 3000;
// En un contenedor hay que escuchar en todas las interfaces, no solo en loopback.
const HOST = process.env.HOST || "0.0.0.0";
const EN_PRODUCCION = process.env.NODE_ENV === "production";
const API_KEY = process.env.ANTHROPIC_API_KEY;
// Modelo: Sonnet 5 es un buen equilibrio calidad/costo/velocidad para extraer y redactar.
// Puedes cambiarlo a "claude-opus-5" (más capaz) o "claude-haiku-4-5" (más barato/rápido).
const MODEL = process.env.KONEKT_MODEL || "claude-sonnet-5";

// Detrás de nginx, Caddy o un balanceador, req.ip sería la IP del proxy y el
// límite de uso de abajo estrangularía a todos los usuarios como si fueran uno.
// TRUST_PROXY=1 hace que Express lea la IP real de X-Forwarded-For.
if (process.env.TRUST_PROXY) app.set("trust proxy", Number(process.env.TRUST_PROXY) || 1);

app.disable("x-powered-by");

// Cabeceras mínimas de seguridad. La app no carga nada de terceros: ni CDN,
// ni tipografías externas, ni iframes. Todo se sirve desde este mismo origen.
app.use((req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "same-origin");
  if (EN_PRODUCCION) {
    res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  }
  next();
});

app.use(express.json({ limit: "1mb" }));
app.use(express.static(path.join(__dirname, "public")));


/* ---------- salud / diagnóstico ----------
   Sin autenticación a propósito: lo consultan Docker, systemd y el monitoreo.
   No revela ningún secreto, solo si la configuración está completa. */
app.get("/api/health", (req, res) => {
  // La base local siempre esta: si el proceso arranco, el archivo existe.
  // Lo unico que puede faltar es la llave de Anthropic, y eso solo afecta
  // a los dos botones de IA del generador, no al CRM.
  let usuarios = -1;
  try { usuarios = db.uno("SELECT COUNT(*) AS n FROM usuarios").n; } catch (e) { usuarios = -1; }
  const listo = usuarios >= 0;
  res.status(listo ? 200 : 503).json({
    ok: listo,
    modelo: MODEL,
    anthropic: !!API_KEY,
    baseDatos: listo ? "sqlite" : "no disponible",
    sinLogin: auth.SIN_LOGIN,
    usuarios,
    entorno: EN_PRODUCCION ? "produccion" : "desarrollo",
  });
});

/* ---------- API del CRM ---------- */
// Prospectos, actividades, clientes, tareas, calendario, plantillas y sesión.
app.use("/api", api.router);

/* ---------- Autenticación ----------
   Vive en rutas/api.js, junto al resto de la sesión. Aquí solo se reutiliza
   para proteger los dos endpoints de IA. */
const requiereSesion = api.requiereSesion;

/* ---------- Límite de uso por usuario ---------- */
// En memoria: se reinicia junto con el proceso. Suficiente para una instancia.
// Con varias réplicas habría que moverlo a Redis o a una tabla de Postgres.
const VENTANA_MS = 5 * 60 * 1000;
const MAX_PETICIONES = Number(process.env.MAX_PETICIONES) || 40;
const usoPorUsuario = new Map();

function limitarUso(req, res, next) {
  const ahora = Date.now();
  const clave = (req.usuario && req.usuario.id) || req.ip || "desconocido";
  const registro = usoPorUsuario.get(clave);

  if (!registro || ahora > registro.reinicioEn) {
    usoPorUsuario.set(clave, { conteo: 1, reinicioEn: ahora + VENTANA_MS });
    return next();
  }
  if (registro.conteo >= MAX_PETICIONES) {
    const segundos = Math.ceil((registro.reinicioEn - ahora) / 1000);
    return res.status(429).json({
      error: `Demasiadas peticiones. Intenta de nuevo en ${segundos} segundos.`,
    });
  }
  registro.conteo++;
  next();
}

// Evita que el Map crezca sin límite en un proceso de larga vida.
const limpieza = setInterval(() => {
  const ahora = Date.now();
  for (const [clave, r] of usoPorUsuario) if (ahora > r.reinicioEn) usoPorUsuario.delete(clave);
}, VENTANA_MS);
limpieza.unref();

/* ---------- Errores hacia el navegador ---------- */
// En producción no se filtra el detalle interno: se registra en el log del
// servidor y al usuario le llega un mensaje genérico.
function responderError(res, e, contexto) {
  console.error(`[${contexto}]`, e.message);
  const esperado = e.esperado === true;
  res.status(500).json({
    error: esperado || !EN_PRODUCCION ? e.message : "Error del servidor. Intenta de nuevo.",
  });
}

/* ---------- Llamada base a Anthropic con "tool use" para forzar JSON ---------- */
async function callClaude({ system, userText, tool, toolName, maxTokens = 8000 }) {
  if (!API_KEY) throw new Error("Falta ANTHROPIC_API_KEY en el servidor (.env)");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: maxTokens,
      system,
      tools: [tool],
      tool_choice: { type: "tool", name: toolName },
      messages: [{ role: "user", content: userText }],
    }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message || "Error de la API de Anthropic");

  // En Sonnet 5 el razonamiento adaptativo está activo por omisión y consume del
  // mismo presupuesto de max_tokens. Si se agota, no llega el bloque estructurado:
  // lo reportamos con un mensaje entendible en vez del error genérico.
  if (data.stop_reason === "max_tokens") {
    const err = new Error(
      "La respuesta se cortó por límite de tokens. Reduce el texto de entrada o sube maxTokens."
    );
    err.esperado = true; // se le puede mostrar al usuario tal cual
    throw err;
  }

  const block = (data.content || []).find((b) => b.type === "tool_use");
  if (!block) throw new Error("La respuesta no trae datos estructurados");
  return block.input;
}

/* ============================================================
   LLAMADA 1 · EXTRACCIÓN  (texto libre -> JSON, SIN inventar)
   ============================================================ */
const EXTRACT_TOOL = {
  name: "guardar_extraccion",
  description: "Guarda los datos del proyecto EXTRAÍDOS del texto. Solo datos explícitos.",
  input_schema: {
    type: "object",
    properties: {
      empresa: { type: ["string", "null"] },
      contacto: { type: ["string", "null"] },
      puesto: { type: ["string", "null"] },
      telefono: { type: ["string", "null"] },
      correo: { type: ["string", "null"] },
      giro: { type: ["string", "null"] },
      ubicacion: { type: ["string", "null"] },
      descripcion_negocio: { type: ["string", "null"] },
      problematica: { type: "array", items: { type: "string" } },
      objetivos: { type: "array", items: { type: "string" } },
      solucion: { type: ["string", "null"] },
      modulos: {
        type: "array",
        items: {
          type: "object",
          properties: {
            nombre: { type: "string" },
            funcionalidades: { type: "array", items: { type: "string" } },
          },
        },
      },
      integraciones: { type: "array", items: { type: "string" } },
      usuarios_roles: { type: "array", items: { type: "string" } },
      precio: { type: ["number", "null"] },
      iva: { type: ["boolean", "null"], description: "true si se menciona que aplica IVA" },
      esquema_pagos: {
        type: "array",
        description: "Esquema EXACTO tal como se menciona (ej. 50/30/20). Vacío si no se menciona.",
        items: {
          type: "object",
          properties: {
            porcentaje: { type: "number" },
            concepto: { type: ["string", "null"] },
          },
        },
      },
      tiempo_implementacion: { type: ["string", "null"] },
      vigencia: { type: ["string", "null"] },
      capacitacion: { type: ["string", "null"] },
      soporte: { type: ["string", "null"] },
      observaciones: { type: ["string", "null"] },
      metricas_proporcionadas: {
        type: "array",
        description: "SOLO cifras que el usuario dio explícitamente o que son calculables con datos dados.",
        items: {
          type: "object",
          properties: { valor: { type: "string" }, descripcion: { type: "string" } },
        },
      },
    },
    required: [],
  },
};

const EXTRACT_SYSTEM = `Eres un asistente que extrae información de un texto libre sobre un proyecto de software para un cliente de la agencia Konekt.

REGLA ABSOLUTA: NO INVENTES NADA. Devuelve únicamente lo que esté EXPLÍCITAMENTE en el texto.
- Si un dato no aparece, devuelve null (o [] para listas).
- Nunca inventes módulos, integraciones, cantidades, porcentajes, ahorros, incrementos de ventas, fechas, precios, tiempos ni condiciones comerciales.
- El esquema de pagos debe ser EXACTO como se menciona (por ejemplo, si dice 50/30/20, devuelve tres etapas con esos porcentajes; NO lo cambies a 50/50).
- metricas_proporcionadas SOLO debe contener cifras dadas por el usuario o calculables con datos dados. Si no hay, deja el arreglo vacío.
Responde únicamente llamando a la herramienta guardar_extraccion.`;

app.post("/api/extract", requiereSesion, limitarUso, async (req, res) => {
  try {
    const texto = (req.body && req.body.texto) || "";
    if (!texto.trim()) return res.status(400).json({ error: "Texto vacío" });
    const out = await callClaude({
      system: EXTRACT_SYSTEM,
      userText: "Texto del proyecto:\n\n" + texto,
      tool: EXTRACT_TOOL,
      toolName: "guardar_extraccion",
      maxTokens: 8000,
    });
    res.json(out);
  } catch (e) {
    responderError(res, e, "/api/extract");
  }
});

/* ============================================================
   LLAMADA 2 · REDACCIÓN  (datos confirmados -> contenido)
   ============================================================ */
const REDACT_TOOL = {
  name: "guardar_propuesta",
  description: "Guarda el contenido redactado de la propuesta, respetando los límites de longitud.",
  input_schema: {
    type: "object",
    properties: {
      titulo: {
        type: "object",
        properties: {
          a: { type: "string", maxLength: 28, description: "Título (parte en negro)" },
          b: { type: "string", maxLength: 20, description: "Palabra destacada en azul" },
        },
      },
      lead: { type: "string", maxLength: 190, description: "Línea de resumen de la portada" },
      heroT: { type: "string", maxLength: 90, description: "Frase corta del recuadro azul" },
      reto: {
        type: "array",
        maxItems: 4,
        description: "Puntos del reto. Cada uno con título corto y descripción breve.",
        items: {
          type: "object",
          properties: {
            titulo: { type: "string", maxLength: 42 },
            desc: { type: "string", maxLength: 150 },
          },
        },
      },
      solucion: {
        type: "object",
        properties: {
          titulo: { type: "string", maxLength: 60 },
          desc: { type: "string", maxLength: 300 },
        },
      },
      modulos: {
        type: "array",
        maxItems: 9,
        description: "SOLO los módulos realmente solicitados.",
        items: {
          type: "object",
          properties: {
            nombre: { type: "string", maxLength: 40 },
            desc: { type: "string", maxLength: 120 },
            tag: { type: "string", maxLength: 28, description: "Beneficio corto (cualitativo)" },
          },
        },
      },
      beneficios: {
        type: "array",
        maxItems: 6,
        description: "Beneficios cualitativos, SIN inventar números.",
        items: { type: "string", maxLength: 72 },
      },
      metricas: {
        type: "array",
        maxItems: 4,
        description: "SOLO si el usuario dio la cifra o es calculable con datos dados. Si no, deja vacío.",
        items: {
          type: "object",
          properties: {
            big: { type: "string", maxLength: 8 },
            lb: { type: "string", maxLength: 22 },
            ds: { type: "string", maxLength: 26 },
          },
        },
      },
    },
    required: [],
  },
};

const REDACT_SYSTEM = `Eres un consultor senior de Konekt que redacta una propuesta comercial a partir de datos CONFIRMADOS (JSON).

Objetivo: que se sienta escrita por alguien que entendió la empresa, no como plantilla genérica.
Reglas:
- Escribe en español, tono profesional, claro y específico.
- NO copies el texto original ni lo repitas literal; sintetiza y reformula.
- Respeta ESTRICTAMENTE los límites de longitud del esquema (si algo es largo, resúmelo).
- Usa SOLO los módulos que estén en los datos. No agregues módulos, integraciones ni funcionalidades que no vengan en los datos.
- NO inventes números. Incluye una métrica numérica en "metricas" únicamente si el dato fue proporcionado (metricas_proporcionadas) o es calculable con datos dados. Si no, deja "metricas" vacío y usa "beneficios" cualitativos.
- "reto": convierte la problemática en 2 a 4 puntos con título corto y una frase clara cada uno.
- "solucion": explica breve y específico cómo Konekt lo resuelve.
Responde únicamente llamando a la herramienta guardar_propuesta.`;

app.post("/api/redactar", requiereSesion, limitarUso, async (req, res) => {
  try {
    const datos = (req.body && req.body.datos) || {};
    const out = await callClaude({
      system: REDACT_SYSTEM,
      userText: "Datos confirmados del proyecto (JSON):\n\n" + JSON.stringify(datos, null, 2),
      tool: REDACT_TOOL,
      toolName: "guardar_propuesta",
      maxTokens: 8000,
    });
    res.json(out);
  } catch (e) {
    responderError(res, e, "/api/redactar");
  }
});

app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "konekt-sales.html"));
});

/* ---------- arranque ---------- */
function aviso(cond, textoOk, textoMal) {
  console.log(`  ${cond ? "✓" : "✗"} ${cond ? textoOk : textoMal}`);
}

const servidor = app.listen(PORT, HOST, () => {
  console.log(`\n  Konekt Sales · ${EN_PRODUCCION ? "producción" : "desarrollo"}`);
  console.log(`  Escuchando en http://${HOST === "0.0.0.0" ? "localhost" : HOST}:${PORT}`);
  console.log(`  Modelo: ${MODEL}\n`);
  if (API_KEY) {
    console.log("  ✓ IA activa (" + MODEL + ")");
  } else {
    console.log("  · Sin llave de Anthropic: los dos botones de IA del generador");
    console.log("    salen desactivados. Todo lo demás funciona igual.");
  }
  console.log("  ✓ Base de datos: " + db.RUTA_DB);
  if (auth.SIN_LOGIN) {
    try { auth.usuarioLocal(); } catch (e) { console.error("[usuario local]", e.message); }
    console.log("  ! SIN_LOGIN activo: se entra sin contraseña y todos comparten");
    console.log("    la misma cartera. Solo para red interna: cualquiera que");
    console.log("    alcance este puerto entra y puede borrar datos.");
  } else {
    let nUsuarios = 0;
    try { nUsuarios = db.uno("SELECT COUNT(*) AS n FROM usuarios").n; } catch (e) {}
    aviso(nUsuarios > 0,
          nUsuarios + " usuario(s) dados de alta",
          "No hay ningún usuario. Crea el primero con:  npm run usuario");
  }
  if (EN_PRODUCCION && !process.env.TRUST_PROXY) {
    console.log("  ! Estás en producción sin TRUST_PROXY. Si hay nginx enfrente,");
    console.log("    ponlo en 1 o el límite de uso tratará a todos como un solo usuario.");
  }
  console.log("");
});

// Las sesiones vencidas se quedarian en la tabla para siempre.
const barrido = setInterval(() => {
  try {
    const n = auth.limpiarSesiones();
    if (n) console.log(`  Sesiones vencidas eliminadas: ${n}`);
  } catch (e) { console.error("[sesiones]", e.message); }
}, 6 * 60 * 60 * 1000);
barrido.unref();

// Cierre ordenado: Docker y systemd mandan SIGTERM y esperan. Sin esto, matan
// el proceso a media petición y el usuario ve una conexión cortada.
let cerrando = false;
function cerrar(senal) {
  if (cerrando) return;
  cerrando = true;
  console.log(`\n  ${senal} recibida, cerrando…`);
  servidor.close(() => {
    db.cerrar();
    console.log("  Servidor cerrado limpiamente.");
    process.exit(0);
  });
  // Si alguna conexión se queda colgada, no esperar para siempre.
  setTimeout(() => {
    console.error("  Cierre forzado tras 10s.");
    process.exit(1);
  }, 10000).unref();
}
process.on("SIGTERM", () => cerrar("SIGTERM"));
process.on("SIGINT", () => cerrar("SIGINT"));

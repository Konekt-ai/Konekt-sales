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
 * Ejecutar:   node server.js      (requiere Node 18+)
 * Abrir:      http://localhost:3000
 */

require("dotenv").config();
const express = require("express");
const path = require("path");

const app = express();
app.use(express.json({ limit: "1mb" }));
app.use(express.static(path.join(__dirname, "public")));

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.ANTHROPIC_API_KEY;
// Modelo: Sonnet 5 es un buen equilibrio calidad/costo/velocidad para extraer y redactar.
// Puedes cambiarlo a "claude-opus-4-8" (más capaz) o "claude-haiku-4-5" (más barato/rápido).
const MODEL = process.env.KONEKT_MODEL || "claude-sonnet-5";

/* ---------- Llamada base a Anthropic con "tool use" para forzar JSON ---------- */
async function callClaude({ system, userText, tool, toolName, maxTokens = 1800 }) {
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

app.post("/api/extract", async (req, res) => {
  try {
    const texto = (req.body && req.body.texto) || "";
    if (!texto.trim()) return res.status(400).json({ error: "Texto vacío" });
    const out = await callClaude({
      system: EXTRACT_SYSTEM,
      userText: "Texto del proyecto:\n\n" + texto,
      tool: EXTRACT_TOOL,
      toolName: "guardar_extraccion",
      maxTokens: 1600,
    });
    res.json(out);
  } catch (e) {
    res.status(500).json({ error: e.message });
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

app.post("/api/redactar", async (req, res) => {
  try {
    const datos = (req.body && req.body.datos) || {};
    const out = await callClaude({
      system: REDACT_SYSTEM,
      userText: "Datos confirmados del proyecto (JSON):\n\n" + JSON.stringify(datos, null, 2),
      tool: REDACT_TOOL,
      toolName: "guardar_propuesta",
      maxTokens: 2000,
    });
    res.json(out);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

/* ---------- salud / diagnóstico ---------- */
app.get("/api/health", (req, res) => {
  res.json({ ok: true, modelo: MODEL, apiKeyConfigurada: !!API_KEY });
});

app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "konekt-sales.html"));
});

app.listen(PORT, () => {
  console.log(`\nKonekt corriendo en  http://localhost:${PORT}`);
  console.log(`Modelo: ${MODEL}`);
  console.log(`API key ${API_KEY ? "detectada ✓" : "NO detectada ✗  (revisa tu .env)"}\n`);
});

/**
 * Konekt Sales · API del CRM
 * --------------------------
 * El navegador ya no habla con ninguna base de datos: habla solo con estas
 * rutas, y estas rutas hablan con SQLite.
 *
 * ⚠️  Aquí vive el control de acceso. Antes lo imponía Postgres con RLS, y
 *     era imposible saltárselo. Ahora es código: CADA consulta de prospectos
 *     tiene que pasar por alcanceLead() o filtrarse con `vendedor_id`. Si una
 *     se salta el filtro, un vendedor ve la cartera de otro y nada lo impide.
 */

const express = require("express");
const db = require("../db");
const auth = require("../db/auth");

const router = express.Router();

/* =====================================================================
 *  Sesión
 * =================================================================== */

const COOKIE = "konekt_sesion";

function leerCookie(req, nombre) {
  const crudo = req.headers.cookie;
  if (!crudo) return null;
  for (const parte of crudo.split(";")) {
    const i = parte.indexOf("=");
    if (i < 0) continue;
    if (parte.slice(0, i).trim() === nombre) {
      return decodeURIComponent(parte.slice(i + 1).trim());
    }
  }
  return null;
}

function ponerCookie(res, token, expira) {
  const trozos = [
    `${COOKIE}=${encodeURIComponent(token)}`,
    "Path=/",
    "HttpOnly",                 // el JavaScript de la página no puede leerla
    "SameSite=Strict",          // no viaja desde otros sitios: corta el CSRF
    `Max-Age=${auth.DIAS_SESION * 86400}`,
  ];
  // Solo con HTTPS. En la red interna va por HTTP, así que se activa por .env.
  if (process.env.COOKIE_SEGURA === "1") trozos.push("Secure");
  res.setHeader("Set-Cookie", trozos.join("; "));
}

function borrarCookie(res) {
  res.setHeader("Set-Cookie", `${COOKIE}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0`);
}

/** Deja req.usuario listo, o corta con 401. */
function requiereSesion(req, res, next) {
  const usuario = auth.usuarioDeSesion(leerCookie(req, COOKIE));
  if (!usuario) return res.status(401).json({ error: "Falta iniciar sesión." });
  req.usuario = usuario;
  next();
}

function requiereAdmin(req, res, next) {
  if (!auth.esAdmin(req.usuario)) {
    return res.status(403).json({ error: "Solo un administrador puede hacer esto." });
  }
  next();
}

/** Envuelve un handler async para que un throw no tumbe el proceso. */
function ruta(fn) {
  return (req, res) => {
    try {
      fn(req, res);
    } catch (e) {
      console.error(`[api ${req.method} ${req.path}]`, e.message);
      const estado = e.estado || 500;
      const publico = e.estado ? e.message : "Error del servidor.";
      res.status(estado).json({ error: publico });
    }
  };
}

function fallo(mensaje, estado = 400) {
  const e = new Error(mensaje);
  e.estado = estado;
  return e;
}

/* =====================================================================
 *  Formato: se arma aquí para que el navegador reciba las cosas listas
 * =================================================================== */

const MESES = ["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"];

function fechaCorta(iso) {
  if (!iso) return "—";
  const [a, m, d] = String(iso).slice(0, 10).split("-");
  if (!a || !m || !d) return "—";
  return `${d} ${MESES[Number(m) - 1]} ${a}`;
}

function horaCorta(iso) {
  if (!iso) return "";
  const t = String(iso).slice(11, 16);
  return t || "";
}

function armarCliente(c, pagos) {
  if (!c) return undefined;
  return {
    id: c.id,
    fechaCierre: fechaCorta(c.fecha_cierre),
    servicio: c.servicio || "",
    precio: Number(c.precio),
    descuento: Number(c.descuento),
    iva: !!c.aplica_iva,
    formaPago: c.forma_pago || "",
    inicio: c.inicio || "Por definir",
    entrega: c.entrega || "Por definir",
    estado: c.estado || "Por iniciar",
    pagos: (pagos || []).map((p) => ({
      n: p.concepto || `Pago ${p.numero}`,
      pct: Number(p.porcentaje),
      monto: Number(p.monto),
      estado: p.estado,
    })),
  };
}

function armarLead(f, cliente) {
  return {
    id: f.id,
    nombre: f.nombre || "",
    empresa: f.empresa || "",
    giro: f.giro || "",
    tel: f.tel || "",
    email: f.email || "",
    fuente: f.fuente || "",
    entrada: fechaCorta(f.entrada),
    vendedor: f.vendedor_nombre || "",
    vendedorId: f.vendedor_id,
    servicio: f.servicio || "",
    necesidad: f.necesidad || "",
    etapa: f.etapa,
    valor: Number(f.valor) || 0,
    prob: Number(f.prob) || 0,
    interes: f.interes || "medio",
    proxAccion: f.prox_accion || "—",
    seguimiento: f.seguimiento ? fechaCorta(f.seguimiento) : "—",
    presupuesto: f.presupuesto || "No especificado",
    objecion: f.objecion || "—",
    notas: f.notas || "",
    ai: null,
    timeline: [],
    docs: [],
    cliente,
  };
}

const SQL_LEAD =
  `SELECT l.*, u.nombre AS vendedor_nombre
     FROM leads l
     LEFT JOIN usuarios u ON u.id = l.vendedor_id`;

function cargarClienteDe(leadId) {
  const c = db.uno("SELECT * FROM clientes WHERE lead_id = ?", leadId);
  if (!c) return undefined;
  const pagos = db.todas("SELECT * FROM pagos WHERE cliente_id = ? ORDER BY numero", c.id);
  return armarCliente(c, pagos);
}

/**
 * Trae un prospecto comprobando que el usuario tenga derecho a verlo.
 * Devuelve 404 (no 403) cuando no le pertenece: así no se puede usar la API
 * para averiguar qué prospectos existen en la cartera de otro.
 */
function alcanceLead(usuario, id) {
  const f = db.uno(`${SQL_LEAD} WHERE l.id = ?`, id);
  if (!f) throw fallo("Prospecto no encontrado.", 404);
  if (!auth.veTodo(usuario) && f.vendedor_id !== usuario.id) {
    throw fallo("Prospecto no encontrado.", 404);
  }
  return f;
}

/* =====================================================================
 *  Autenticación
 * =================================================================== */

router.post("/auth/entrar", ruta((req, res) => {
  const { email, password } = req.body || {};
  let s;
  try {
    s = auth.iniciarSesion(email, password);
  } catch (e) {
    throw fallo(e.message, 401);
  }
  ponerCookie(res, s.token, s.expira);
  res.json({ usuario: s.usuario });
}));

router.post("/auth/salir", ruta((req, res) => {
  auth.cerrarSesion(leerCookie(req, COOKIE));
  borrarCookie(res);
  res.json({ ok: true });
}));

router.get("/auth/yo", ruta((req, res) => {
  const usuario = auth.usuarioDeSesion(leerCookie(req, COOKIE));
  if (!usuario) return res.status(401).json({ error: "Sin sesión." });
  res.json({ usuario });
}));

// A partir de aquí, todo exige sesión.
router.use(requiereSesion);

/* =====================================================================
 *  Prospectos
 * =================================================================== */

router.get("/leads", ruta((req, res) => {
  const filas = auth.veTodo(req.usuario)
    ? db.todas(`${SQL_LEAD} ORDER BY l.creado_at DESC`)
    : db.todas(`${SQL_LEAD} WHERE l.vendedor_id = ? ORDER BY l.creado_at DESC`, req.usuario.id);
  res.json(filas.map((f) => armarLead(f, cargarClienteDe(f.id))));
}));

router.get("/leads/:id", ruta((req, res) => {
  const f = alcanceLead(req.usuario, req.params.id);
  res.json(armarLead(f, cargarClienteDe(f.id)));
}));

const CAMPOS_LEAD = {
  nombre: "nombre", empresa: "empresa", giro: "giro", tel: "tel", email: "email",
  fuente: "fuente", servicio: "servicio", necesidad: "necesidad", etapa: "etapa",
  valor: "valor", prob: "prob", interes: "interes", proxAccion: "prox_accion",
  seguimiento: "seguimiento", presupuesto: "presupuesto", objecion: "objecion",
  notas: "notas",
};

router.post("/leads", ruta((req, res) => {
  const d = req.body || {};
  if (!d.nombre || !String(d.nombre).trim()) throw fallo("El nombre del contacto es obligatorio.");

  const id = db.nuevoId();
  db.correr(
    `INSERT INTO leads (id, vendedor_id, nombre, empresa, giro, tel, email, fuente,
                        servicio, necesidad, etapa, valor, prob, interes,
                        prox_accion, seguimiento, presupuesto, notas, entrada)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
    id, req.usuario.id,
    String(d.nombre).trim(), d.empresa || "", d.giro || "", d.tel || "", d.email || "",
    d.fuente || "Directo", d.servicio || "", d.necesidad || "",
    d.etapa || "nuevo", Number(d.valor) || 0, Number(d.prob) || 0, d.interes || "medio",
    d.proxAccion || "", d.seguimiento || null, d.presupuesto || "", d.notas || "",
    db.hoy()
  );
  const f = db.uno(`${SQL_LEAD} WHERE l.id = ?`, id);
  res.status(201).json(armarLead(f, undefined));
}));

router.patch("/leads/:id", ruta((req, res) => {
  const actual = alcanceLead(req.usuario, req.params.id);
  const d = req.body || {};

  const sets = [];
  const vals = [];
  for (const [entrada, columna] of Object.entries(CAMPOS_LEAD)) {
    if (Object.prototype.hasOwnProperty.call(d, entrada)) {
      sets.push(`${columna} = ?`);
      let v = d[entrada];
      if (columna === "valor" || columna === "prob") v = Number(v) || 0;
      if (columna === "seguimiento" && !v) v = null;
      vals.push(v);
    }
  }
  if (!sets.length) throw fallo("No mandaste nada que actualizar.");

  vals.push(actual.id);
  db.correr(`UPDATE leads SET ${sets.join(", ")} WHERE id = ?`, ...vals);

  // Pasar a "ganado" crea la ficha de cliente con el esquema 50/30/20,
  // igual que hacía la versión anterior.
  if (d.etapa === "ganado" && actual.etapa !== "ganado") {
    if (!db.uno("SELECT id FROM clientes WHERE lead_id = ?", actual.id)) {
      crearClienteDesdeLead(actual.id);
    }
  }

  const f = db.uno(`${SQL_LEAD} WHERE l.id = ?`, actual.id);
  res.json(armarLead(f, cargarClienteDe(f.id)));
}));

router.delete("/leads/:id", ruta((req, res) => {
  const f = alcanceLead(req.usuario, req.params.id);
  if (f.vendedor_id !== req.usuario.id && !auth.esAdmin(req.usuario)) {
    throw fallo("Solo el vendedor asignado o un administrador puede borrarlo.", 403);
  }
  db.correr("DELETE FROM leads WHERE id = ?", f.id);
  res.json({ ok: true });
}));

function crearClienteDesdeLead(leadId) {
  const l = db.uno("SELECT * FROM leads WHERE id = ?", leadId);
  const iva = l.valor * 0.16;
  const total = l.valor + iva;
  const p1 = Math.round(total * 0.5);
  const p2 = Math.round(total * 0.3);
  const idCliente = db.nuevoId();

  db.enTransaccion(() => {
    db.correr(
      `INSERT INTO clientes (id, lead_id, servicio, precio, forma_pago)
       VALUES (?,?,?,?,?)`,
      idCliente, leadId, l.servicio || "", l.valor, "50% / 30% / 20%"
    );
    const filas = [
      [1, "Pago 1", 50, p1],
      [2, "Pago 2", 30, p2],
      [3, "Pago 3", 20, total - p1 - p2],
    ];
    for (const [n, concepto, pct, monto] of filas) {
      db.correr(
        `INSERT INTO pagos (cliente_id, numero, concepto, porcentaje, monto)
         VALUES (?,?,?,?,?)`,
        idCliente, n, concepto, pct, monto
      );
    }
  });
  return idCliente;
}

/* =====================================================================
 *  Actividades
 * =================================================================== */

router.get("/leads/:id/actividades", ruta((req, res) => {
  const f = alcanceLead(req.usuario, req.params.id);
  const filas = db.todas(
    "SELECT * FROM actividades WHERE lead_id = ? ORDER BY ocurrio_at, id", f.id
  );
  res.json(filas.map((a) => ({
    dt: fechaCorta(a.ocurrio_at),
    tx: a.titulo,
    sub: a.detalle || "",
    cls: a.tipo === "sistema" ? "mut" : "",
  })));
}));

router.post("/leads/:id/actividades", ruta((req, res) => {
  const f = alcanceLead(req.usuario, req.params.id);
  const { titulo, detalle, tipo } = req.body || {};
  if (!titulo || !String(titulo).trim()) throw fallo("Falta el título de la actividad.");
  db.correr(
    `INSERT INTO actividades (lead_id, usuario_id, titulo, detalle, tipo)
     VALUES (?,?,?,?,?)`,
    f.id, req.usuario.id, String(titulo).trim(), detalle || "", tipo || "nota"
  );
  res.status(201).json({ ok: true });
}));

/* =====================================================================
 *  Documentos y folios
 * =================================================================== */

router.get("/leads/:id/documentos", ruta((req, res) => {
  const f = alcanceLead(req.usuario, req.params.id);
  const filas = db.todas(
    "SELECT id, tipo, folio, creado_at FROM documentos WHERE lead_id = ? ORDER BY creado_at DESC",
    f.id
  );
  res.json(filas.map((d) => ({
    t: d.tipo === "propuesta" ? "Propuesta comercial" : `Cotización ${d.folio || ""}`.trim(),
    d: fechaCorta(d.creado_at),
  })));
}));

router.post("/documentos", ruta((req, res) => {
  const { leadId, tipo, payload, folio } = req.body || {};
  if (tipo !== "propuesta" && tipo !== "cotizacion") throw fallo("Tipo de documento inválido.");
  if (!payload) throw fallo("Falta el contenido del documento.");
  if (leadId) alcanceLead(req.usuario, leadId); // comprueba el permiso

  const id = db.nuevoId();
  db.correr(
    `INSERT INTO documentos (id, lead_id, tipo, folio, payload, creado_por)
     VALUES (?,?,?,?,?,?)`,
    id, leadId || null, tipo, folio || null, JSON.stringify(payload), req.usuario.id
  );
  res.status(201).json({ id });
}));

router.post("/folios/siguiente", ruta((req, res) => {
  res.json({ folio: db.siguienteFolio((req.body && req.body.serie) || "CA") });
}));

/* =====================================================================
 *  Recurrentes
 * =================================================================== */

router.get("/recurrentes", ruta((req, res) => {
  const base =
    `SELECT r.*, l.empresa, l.vendedor_id
       FROM recurrentes r
       JOIN clientes c ON c.id = r.cliente_id
       JOIN leads    l ON l.id = c.lead_id`;
  const filas = auth.veTodo(req.usuario)
    ? db.todas(`${base} ORDER BY r.prox_cobro`)
    : db.todas(`${base} WHERE l.vendedor_id = ? ORDER BY r.prox_cobro`, req.usuario.id);

  res.json(filas.map((r) => ({
    empresa: r.empresa || "—",
    servicio: r.servicio,
    mensualidad: Number(r.mensualidad),
    proxCobro: fechaCorta(r.prox_cobro),
    ultimo: fechaCorta(r.ultimo_cobro),
    estado: r.estado,
    renovacion: r.renovacion,
    contrato: !!r.contrato,
  })));
}));

/* =====================================================================
 *  Tareas
 * =================================================================== */

router.get("/tareas", ruta((req, res) => {
  const dia = db.hoy();
  const filas = db.todas(
    `SELECT t.*, l.nombre AS lead_nombre
       FROM tareas t
       LEFT JOIN leads l ON l.id = t.lead_id
      WHERE t.usuario_id = ? AND substr(t.vence_at, 1, 10) = ?
      ORDER BY t.vence_at`,
    req.usuario.id, dia
  );
  res.json(filas.map((t) => ({
    id: t.id,
    hora: horaCorta(t.vence_at),
    tx: t.titulo,
    prospecto: t.lead_nombre || "—",
    tipo: t.tipo,
    done: !!t.hecha_at,
    lead: t.lead_id,
  })));
}));

router.post("/tareas", ruta((req, res) => {
  const { titulo, tipo, venceAt, leadId } = req.body || {};
  if (!titulo || !String(titulo).trim()) throw fallo("Falta el título de la tarea.");
  if (!venceAt) throw fallo("Falta la fecha y hora.");
  if (leadId) alcanceLead(req.usuario, leadId);
  const r = db.correr(
    `INSERT INTO tareas (usuario_id, lead_id, titulo, tipo, vence_at)
     VALUES (?,?,?,?,?)`,
    req.usuario.id, leadId || null, String(titulo).trim(), tipo || "task", venceAt
  );
  res.status(201).json({ id: Number(r.lastInsertRowid) });
}));

router.patch("/tareas/:id", ruta((req, res) => {
  const t = db.uno("SELECT * FROM tareas WHERE id = ?", Number(req.params.id));
  if (!t || t.usuario_id !== req.usuario.id) throw fallo("Tarea no encontrada.", 404);
  const hecha = !!(req.body && req.body.done);
  db.correr("UPDATE tareas SET hecha_at = ? WHERE id = ?", hecha ? db.ahora() : null, t.id);
  res.json({ ok: true });
}));

/* =====================================================================
 *  Calendario
 * =================================================================== */

router.get("/eventos", ruta((req, res) => {
  const anio = Number(req.query.anio) || new Date().getFullYear();
  const mes = String(Number(req.query.mes) || new Date().getMonth() + 1).padStart(2, "0");
  const prefijo = `${anio}-${mes}`;

  const base =
    `SELECT * FROM eventos WHERE substr(inicio, 1, 7) = ?`;
  const filas = auth.veTodo(req.usuario)
    ? db.todas(`${base} ORDER BY inicio`, prefijo)
    : db.todas(`${base} AND usuario_id = ? ORDER BY inicio`, prefijo, req.usuario.id);

  const porDia = {};
  for (const e of filas) {
    const dia = Number(String(e.inicio).slice(8, 10));
    (porDia[dia] = porDia[dia] || []).push({ t: e.tipo, x: e.titulo, hora: horaCorta(e.inicio) });
  }
  res.json(porDia);
}));

router.post("/eventos", ruta((req, res) => {
  const { titulo, tipo, inicio, leadId } = req.body || {};
  if (!titulo || !inicio) throw fallo("Faltan el título y la fecha del evento.");
  if (leadId) alcanceLead(req.usuario, leadId);
  db.correr(
    `INSERT INTO eventos (usuario_id, lead_id, titulo, tipo, inicio) VALUES (?,?,?,?,?)`,
    req.usuario.id, leadId || null, titulo, tipo || "call", inicio
  );
  res.status(201).json({ ok: true });
}));

/* =====================================================================
 *  Plantillas del generador
 * =================================================================== */

router.get("/plantillas", ruta((req, res) => {
  res.json(db.todas(
    `SELECT id, nombre, alcance FROM plantillas
      WHERE dueno_id = ? OR alcance = 'equipo' ORDER BY nombre`,
    req.usuario.id
  ));
}));

router.get("/plantillas/:nombre", ruta((req, res) => {
  const f = db.uno(
    `SELECT payload FROM plantillas
      WHERE nombre = ? AND (dueno_id = ? OR alcance = 'equipo') LIMIT 1`,
    req.params.nombre, req.usuario.id
  );
  if (!f) throw fallo("Plantilla no encontrada.", 404);
  res.json({ payload: JSON.parse(f.payload) });
}));

router.post("/plantillas", ruta((req, res) => {
  const { nombre, payload, alcance } = req.body || {};
  if (!nombre || !String(nombre).trim()) throw fallo("Falta el nombre de la plantilla.");
  if (!payload) throw fallo("Falta el contenido de la plantilla.");

  const existente = db.uno(
    "SELECT id FROM plantillas WHERE dueno_id = ? AND nombre = ?",
    req.usuario.id, String(nombre).trim()
  );
  if (existente) {
    db.correr(
      "UPDATE plantillas SET payload = ?, alcance = ? WHERE id = ?",
      JSON.stringify(payload), alcance || "personal", existente.id
    );
    return res.json({ id: existente.id });
  }
  const id = db.nuevoId();
  db.correr(
    `INSERT INTO plantillas (id, nombre, alcance, payload, dueno_id) VALUES (?,?,?,?,?)`,
    id, String(nombre).trim(), alcance || "personal", JSON.stringify(payload), req.usuario.id
  );
  res.status(201).json({ id });
}));

router.delete("/plantillas/:nombre", ruta((req, res) => {
  // Solo se borran las propias: las del equipo las quita su dueño o un admin.
  const r = db.correr(
    "DELETE FROM plantillas WHERE nombre = ? AND dueno_id = ?",
    req.params.nombre, req.usuario.id
  );
  if (!r.changes && !auth.esAdmin(req.usuario)) throw fallo("Plantilla no encontrada.", 404);
  if (!r.changes) db.correr("DELETE FROM plantillas WHERE nombre = ?", req.params.nombre);
  res.json({ ok: true });
}));

/* =====================================================================
 *  Usuarios (solo admin)
 * =================================================================== */

router.get("/usuarios", requiereAdmin, ruta((req, res) => {
  res.json(auth.listarUsuarios());
}));

router.post("/usuarios", requiereAdmin, ruta((req, res) => {
  const { email, password, nombre, rol } = req.body || {};
  try {
    res.status(201).json(auth.crearUsuario({ email, password, nombre, rol }));
  } catch (e) {
    throw fallo(e.message, 400);
  }
}));

module.exports = { router, requiereSesion, leerCookie, COOKIE };

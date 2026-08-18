/**
 * Konekt Sales · conexión a la base de datos
 * ------------------------------------------
 * SQLite, usando el módulo `node:sqlite` que viene dentro de Node 22.5+.
 * No hay dependencias que instalar ni servicio que mantener corriendo:
 * toda la base es un solo archivo.
 *
 * Respaldar = copiar ese archivo. Migrar a Linux = copiar ese archivo.
 */

const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const RAIZ = path.join(__dirname, "..");
const RUTA_DB = process.env.DB_RUTA || path.join(RAIZ, "datos", "konekt.db");

fs.mkdirSync(path.dirname(RUTA_DB), { recursive: true });

const db = new DatabaseSync(RUTA_DB);

// --- Ajustes que importan --------------------------------------------
// WAL: permite leer mientras alguien escribe. Sin esto, con dos vendedores
// usando la app al mismo tiempo aparecen errores de "database is locked".
db.exec("PRAGMA journal_mode = WAL");
// SQLite no aplica las llaves foráneas si no se le pide explícitamente.
db.exec("PRAGMA foreign_keys = ON");
// Espera hasta 5s si la base está ocupada en vez de fallar de inmediato.
db.exec("PRAGMA busy_timeout = 5000");
// NORMAL con WAL es seguro ante caída de la aplicación y bastante más rápido
// que FULL en un disco lento.
db.exec("PRAGMA synchronous = NORMAL");

// --- Esquema ----------------------------------------------------------
// Se aplica en cada arranque. Todo es CREATE ... IF NOT EXISTS.
db.exec(fs.readFileSync(path.join(__dirname, "esquema.sql"), "utf8"));

/* ---------------------------------------------------------------------
 *  Ayudas
 * ------------------------------------------------------------------- */

const { randomUUID } = require("node:crypto");

/** Una fila, o null. */
function uno(sql, ...params) {
  const r = db.prepare(sql).get(...params);
  return r === undefined ? null : r;
}

/** Todas las filas. */
function todas(sql, ...params) {
  return db.prepare(sql).all(...params);
}

/** INSERT / UPDATE / DELETE. Devuelve { changes, lastInsertRowid }. */
function correr(sql, ...params) {
  return db.prepare(sql).run(...params);
}

/**
 * Envuelve varias escrituras en una transacción. Si la función lanza,
 * no queda nada a medias.
 */
function enTransaccion(fn) {
  db.exec("BEGIN");
  try {
    const r = fn();
    db.exec("COMMIT");
    return r;
  } catch (e) {
    try { db.exec("ROLLBACK"); } catch (_) { /* la transacción ya murió */ }
    throw e;
  }
}

/** Fecha-hora actual en ISO, como la guarda SQLite: 'YYYY-MM-DD HH:MM:SS'. */
function ahora() {
  return new Date().toISOString().slice(0, 19).replace("T", " ");
}

/** Solo la fecha: 'YYYY-MM-DD'. */
function hoy() {
  const f = new Date();
  return `${f.getFullYear()}-${String(f.getMonth() + 1).padStart(2, "0")}-${String(f.getDate()).padStart(2, "0")}`;
}

/**
 * Siguiente folio de la serie (CA-001, CA-002...).
 * Va en transacción para que dos vendedores no saquen el mismo número.
 */
function siguienteFolio(serie = "CA") {
  return enTransaccion(() => {
    correr("INSERT OR IGNORE INTO folios(serie, consecutivo) VALUES (?, 0)", serie);
    correr("UPDATE folios SET consecutivo = consecutivo + 1 WHERE serie = ?", serie);
    const f = uno("SELECT consecutivo FROM folios WHERE serie = ?", serie);
    return `${serie}-${String(f.consecutivo).padStart(3, "0")}`;
  });
}

/** Cierra la base limpiamente. Se llama al apagar el servidor. */
function cerrar() {
  try { db.close(); } catch (_) { /* ya estaba cerrada */ }
}

module.exports = {
  db,
  RUTA_DB,
  uno,
  todas,
  correr,
  enTransaccion,
  ahora,
  hoy,
  siguienteFolio,
  nuevoId: randomUUID,
  cerrar,
};

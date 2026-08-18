#!/usr/bin/env node
/**
 * Konekt Sales · respaldo de la base
 *
 *   npm run respaldar
 *   npm run respaldar -- D:\respaldos-konekt
 *
 * Al salir de Supabase, los respaldos dejaron de ser problema de alguien más.
 * Toda la cartera de ventas vive en un archivo dentro de datos/. Si ese disco
 * muere sin copias, se pierde todo.
 *
 * Se usa VACUUM INTO en vez de copiar el archivo: genera una copia consistente
 * aunque alguien esté usando la aplicación en ese momento. Copiar el .db a mano
 * mientras hay escrituras puede dejar un archivo corrupto.
 *
 * Conserva los últimos 30 respaldos y borra los más viejos.
 */

require("dotenv").config();

const fs = require("node:fs");
const path = require("node:path");
const db = require("../db");

const CONSERVAR = Number(process.env.RESPALDOS_CONSERVAR) || 30;

const destino =
  process.argv[2] ||
  process.env.RESPALDOS_RUTA ||
  path.join(__dirname, "..", "respaldos");

fs.mkdirSync(destino, { recursive: true });

const f = new Date();
const sello =
  `${f.getFullYear()}${String(f.getMonth() + 1).padStart(2, "0")}${String(f.getDate()).padStart(2, "0")}` +
  `-${String(f.getHours()).padStart(2, "0")}${String(f.getMinutes()).padStart(2, "0")}`;

const archivo = path.join(destino, `konekt-${sello}.db`);

try {
  // VACUUM INTO exige que el archivo no exista todavía.
  if (fs.existsSync(archivo)) fs.unlinkSync(archivo);

  db.db.exec(`VACUUM INTO '${archivo.replace(/'/g, "''")}'`);

  const mb = (fs.statSync(archivo).size / 1048576).toFixed(2);
  console.log(`  Respaldo hecho: ${archivo}  (${mb} MB)`);

  // Rotación: se quedan los más recientes.
  const previos = fs
    .readdirSync(destino)
    .filter((n) => /^konekt-\d{8}-\d{4}\.db$/.test(n))
    .sort()
    .reverse();

  const sobran = previos.slice(CONSERVAR);
  for (const n of sobran) {
    fs.unlinkSync(path.join(destino, n));
  }
  if (sobran.length) console.log(`  Respaldos viejos borrados: ${sobran.length}`);
  console.log(`  Se conservan ${Math.min(previos.length, CONSERVAR)} de ${CONSERVAR}.`);

  db.cerrar();
} catch (e) {
  console.error(`  Falló el respaldo: ${e.message}`);
  process.exit(1);
}

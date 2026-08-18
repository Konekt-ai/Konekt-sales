/**
 * Konekt Sales · usuarios y sesiones
 * ----------------------------------
 * Esto reemplaza lo que antes hacía Supabase Auth.
 *
 * Contraseñas: scrypt de node:crypto. Es el algoritmo recomendado por el
 * propio Node, resiste ataques con GPU y no necesita compilar nada (bcrypt y
 * argon2 traen binarios nativos que en Windows suelen pedir Visual Studio).
 *
 * Sesiones: un token aleatorio guardado en la tabla `sesiones` y enviado al
 * navegador en una cookie httpOnly. El navegador no puede leerla desde
 * JavaScript, así que un XSS no se lleva la sesión.
 */

const crypto = require("node:crypto");
const { uno, todas, correr, ahora, nuevoId } = require("./index");

const DIAS_SESION = 14;
const LARGO_CLAVE = 64;
const COSTO = 16384; // parámetro N de scrypt

/* ---------------------------------------------------------------------
 *  Contraseñas
 * ------------------------------------------------------------------- */

function hashear(password) {
  const sal = crypto.randomBytes(16).toString("hex");
  const clave = crypto.scryptSync(password, sal, LARGO_CLAVE, { N: COSTO }).toString("hex");
  return `scrypt$${COSTO}$${sal}$${clave}`;
}

function verificar(password, guardado) {
  try {
    const [algoritmo, costo, sal, esperado] = String(guardado).split("$");
    if (algoritmo !== "scrypt") return false;
    const calculado = crypto.scryptSync(password, sal, LARGO_CLAVE, { N: Number(costo) });
    const bufEsperado = Buffer.from(esperado, "hex");
    // timingSafeEqual exige longitudes iguales; si difieren, no coinciden.
    if (bufEsperado.length !== calculado.length) return false;
    return crypto.timingSafeEqual(bufEsperado, calculado);
  } catch (e) {
    return false;
  }
}

/* ---------------------------------------------------------------------
 *  Usuarios
 * ------------------------------------------------------------------- */

function crearUsuario({ email, password, nombre, rol }) {
  const correo = String(email || "").trim().toLowerCase();
  if (!correo.includes("@")) throw new Error("El correo no es válido.");
  if (!password || password.length < 8) {
    throw new Error("La contraseña debe tener al menos 8 caracteres.");
  }
  if (uno("SELECT id FROM usuarios WHERE email = ?", correo)) {
    throw new Error(`Ya existe un usuario con el correo ${correo}.`);
  }
  const id = nuevoId();
  correr(
    `INSERT INTO usuarios (id, email, password_hash, nombre, rol)
     VALUES (?, ?, ?, ?, ?)`,
    id, correo, hashear(password), nombre || correo.split("@")[0], rol || "vendedor"
  );
  return uno("SELECT id, email, nombre, rol, activo FROM usuarios WHERE id = ?", id);
}

function listarUsuarios() {
  return todas("SELECT id, email, nombre, rol, activo, creado_at FROM usuarios ORDER BY nombre");
}

function cambiarPassword(usuarioId, password) {
  if (!password || password.length < 8) {
    throw new Error("La contraseña debe tener al menos 8 caracteres.");
  }
  correr("UPDATE usuarios SET password_hash = ? WHERE id = ?", hashear(password), usuarioId);
  // Cerrar las sesiones abiertas: si cambió la contraseña, las anteriores
  // no deberían seguir sirviendo.
  correr("DELETE FROM sesiones WHERE usuario_id = ?", usuarioId);
}

/* ---------------------------------------------------------------------
 *  Sesiones
 * ------------------------------------------------------------------- */

function iniciarSesion(email, password) {
  const correo = String(email || "").trim().toLowerCase();
  const u = uno("SELECT * FROM usuarios WHERE email = ?", correo);

  // Se verifica siempre, aunque el usuario no exista, para que el tiempo de
  // respuesta no delate qué correos están dados de alta.
  const guardado = u ? u.password_hash : "scrypt$16384$00$00";
  const ok = verificar(password, guardado);

  if (!u || !ok) throw new Error("Correo o contraseña incorrectos.");
  if (!u.activo) throw new Error("Esta cuenta está desactivada.");

  const token = crypto.randomBytes(32).toString("hex");
  const expira = new Date(Date.now() + DIAS_SESION * 864e5)
    .toISOString().slice(0, 19).replace("T", " ");

  correr(
    "INSERT INTO sesiones (token, usuario_id, expira_at) VALUES (?, ?, ?)",
    token, u.id, expira
  );

  return {
    token,
    expira,
    usuario: { id: u.id, email: u.email, nombre: u.nombre, rol: u.rol },
  };
}

function usuarioDeSesion(token) {
  if (!token) return null;
  const f = uno(
    `SELECT u.id, u.email, u.nombre, u.rol, u.activo, s.expira_at
       FROM sesiones s
       JOIN usuarios u ON u.id = s.usuario_id
      WHERE s.token = ?`,
    token
  );
  if (!f) return null;
  if (f.expira_at <= ahora()) {
    correr("DELETE FROM sesiones WHERE token = ?", token);
    return null;
  }
  if (!f.activo) return null;
  return { id: f.id, email: f.email, nombre: f.nombre, rol: f.rol };
}

function cerrarSesion(token) {
  if (token) correr("DELETE FROM sesiones WHERE token = ?", token);
}

/** Borra las sesiones vencidas. Se llama de vez en cuando desde server.js. */
function limpiarSesiones() {
  const r = correr("DELETE FROM sesiones WHERE expira_at <= ?", ahora());
  return r.changes;
}

/* ---------------------------------------------------------------------
 *  Modo sin login
 * ------------------------------------------------------------------- */
/**
 * Con SIN_LOGIN=1 no se pide contraseña: todo el mundo entra directo y
 * comparte un mismo usuario local. Está pensado para una red interna.
 *
 * No se borró nada del sistema de sesiones: sigue completo aquí arriba.
 * Para volver a pedir contraseña basta con quitar SIN_LOGIN del .env y dar
 * de alta usuarios con  npm run usuario.
 *
 * El usuario local existe de verdad en la tabla para que los prospectos, las
 * actividades y los documentos sigan teniendo dueño y las llaves foráneas se
 * cumplan. Si mañana se activa el login, todo lo capturado queda colgando de
 * él y no se pierde nada.
 */
const SIN_LOGIN = process.env.SIN_LOGIN === "1";
const CORREO_LOCAL = "local@konekt";

let cacheLocal = null;

function usuarioLocal() {
  if (cacheLocal) return cacheLocal;
  let u = uno("SELECT id, email, nombre, rol FROM usuarios WHERE email = ?", CORREO_LOCAL);
  if (!u) {
    const id = nuevoId();
    correr(
      "INSERT INTO usuarios (id, email, password_hash, nombre, rol) VALUES (?, ?, ?, ?, ?)",
      id, CORREO_LOCAL, "sin-login", process.env.USUARIO_NOMBRE || "Konekt", "admin"
    );
    u = uno("SELECT id, email, nombre, rol FROM usuarios WHERE id = ?", id);
  }
  cacheLocal = u;
  return u;
}

/* ---------------------------------------------------------------------
 *  Alcance por rol
 * ------------------------------------------------------------------- */

/**
 * Antes esto lo hacían las políticas RLS dentro de Postgres. Ahora vive aquí,
 * y por eso TODA consulta de prospectos tiene que pasar por esta función:
 * si alguna se salta el filtro, un vendedor vería la cartera de otro.
 */
function veTodo(usuario) {
  return usuario && (usuario.rol === "gerente" || usuario.rol === "admin");
}

function esAdmin(usuario) {
  return usuario && usuario.rol === "admin";
}

module.exports = {
  SIN_LOGIN,
  usuarioLocal,
  hashear,
  verificar,
  crearUsuario,
  listarUsuarios,
  cambiarPassword,
  iniciarSesion,
  usuarioDeSesion,
  cerrarSesion,
  limpiarSesiones,
  veTodo,
  esAdmin,
  DIAS_SESION,
};

#!/usr/bin/env node
/**
 * Konekt Sales · alta y administración de usuarios
 *
 *   npm run usuario -- crear   diego@konekt.mx "Diego Lizarraga" admin
 *   npm run usuario -- listar
 *   npm run usuario -- clave   diego@konekt.mx
 *   npm run usuario -- baja    diego@konekt.mx
 *   npm run usuario -- alta    diego@konekt.mx
 *
 * La contraseña se pide aparte y no se ve al escribirla, para que no quede
 * en el historial de la terminal.
 */

require("dotenv").config();

const readline = require("node:readline");
const db = require("../db");
const auth = require("../db/auth");

const ROLES = ["vendedor", "gerente", "admin"];

function preguntarOculto(texto) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    // Se apaga el eco de la terminal mientras se escribe la contraseña.
    const escribir = rl._writeToOutput;
    rl._writeToOutput = function (s) {
      if (s.includes(texto)) escribir.call(rl, s);
    };
    rl.question(texto, (v) => {
      rl._writeToOutput = escribir;
      rl.close();
      process.stdout.write("\n");
      resolve(v);
    });
  });
}

async function pedirPassword() {
  const a = await preguntarOculto("  Contraseña (mínimo 8): ");
  if (!a || a.length < 8) {
    console.error("  La contraseña debe tener al menos 8 caracteres.");
    process.exit(1);
  }
  const b = await preguntarOculto("  Repítela: ");
  if (a !== b) {
    console.error("  No coinciden.");
    process.exit(1);
  }
  return a;
}

function buscar(email) {
  const u = db.uno("SELECT * FROM usuarios WHERE email = ?", String(email || "").toLowerCase());
  if (!u) {
    console.error(`  No existe ningún usuario con el correo ${email}.`);
    process.exit(1);
  }
  return u;
}

async function principal() {
  const [accion, email, nombre, rol] = process.argv.slice(2);

  switch (accion) {
    case "crear": {
      if (!email) { console.error("  Falta el correo."); process.exit(1); }
      if (rol && !ROLES.includes(rol)) {
        console.error(`  Rol inválido. Usa uno de: ${ROLES.join(", ")}`);
        process.exit(1);
      }
      console.log(`\n  Creando ${email} (${rol || "vendedor"})`);
      const password = await pedirPassword();
      const u = auth.crearUsuario({ email, password, nombre, rol });
      console.log(`\n  Listo: ${u.nombre} <${u.email}> con rol ${u.rol}\n`);
      break;
    }

    case "listar": {
      const filas = auth.listarUsuarios();
      if (!filas.length) {
        console.log("\n  No hay usuarios. Crea el primero:\n");
        console.log('    npm run usuario -- crear tu@correo.mx "Tu Nombre" admin\n');
        break;
      }
      console.log("");
      for (const u of filas) {
        const estado = u.activo ? " " : " (dado de baja)";
        console.log(`  ${u.rol.padEnd(9)} ${u.email.padEnd(30)} ${u.nombre}${estado}`);
      }
      console.log("");
      break;
    }

    case "clave": {
      const u = buscar(email);
      console.log(`\n  Nueva contraseña para ${u.email}`);
      const password = await pedirPassword();
      auth.cambiarPassword(u.id, password);
      console.log("\n  Cambiada. Sus sesiones abiertas se cerraron.\n");
      break;
    }

    case "baja":
    case "alta": {
      const u = buscar(email);
      const activo = accion === "alta" ? 1 : 0;
      db.correr("UPDATE usuarios SET activo = ? WHERE id = ?", activo, u.id);
      if (!activo) db.correr("DELETE FROM sesiones WHERE usuario_id = ?", u.id);
      console.log(`\n  ${u.email} quedó ${activo ? "activo" : "dado de baja"}.\n`);
      break;
    }

    default:
      console.log(`
  Uso:
    npm run usuario -- crear  <correo> "<nombre>" [vendedor|gerente|admin]
    npm run usuario -- listar
    npm run usuario -- clave  <correo>
    npm run usuario -- baja   <correo>
    npm run usuario -- alta   <correo>
`);
      process.exit(process.argv.length > 2 ? 1 : 0);
  }

  db.cerrar();
}

principal().catch((e) => {
  console.error("\n  " + e.message + "\n");
  process.exit(1);
});

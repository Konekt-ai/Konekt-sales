/* =====================================================================
 *  Konekt Sales · capa de datos
 *  ---------------------------------------------------------------
 *  El navegador ya no habla con ninguna base de datos: solo llama a la
 *  API de este mismo servidor, que es quien guarda todo en SQLite.
 *
 *  La sesión viaja en una cookie httpOnly que el navegador manda sola.
 *  No hay tokens en localStorage, así que un XSS no puede robarse la
 *  sesión.
 *
 *  La interfaz de este objeto es la misma de antes: si algún día se
 *  cambia SQLite por otra cosa, se reescribe el servidor y esto no se
 *  entera.
 * ===================================================================== */
(function () {
  "use strict";

  const BASE = window.KONEKT_API_BASE || "";

  /* ---------------- llamada base ---------------- */

  async function pedir(metodo, ruta, cuerpo) {
    let res;
    try {
      res = await fetch(BASE + "/api" + ruta, {
        method: metodo,
        headers: cuerpo ? { "Content-Type": "application/json" } : {},
        // La cookie de sesión va sola, pero hay que pedirlo explícitamente.
        credentials: "same-origin",
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
      });
    } catch (e) {
      throw new Error("No se pudo conectar con el servidor. ¿Sigue encendido?");
    }

    if (res.status === 204) return null;

    let datos = null;
    try { datos = await res.json(); } catch (e) { /* respuesta sin cuerpo */ }

    if (!res.ok) {
      const msg = (datos && datos.error) || `Error ${res.status}`;
      const err = new Error(msg);
      err.estado = res.status;
      throw err;
    }
    return datos;
  }

  const GET    = (r)    => pedir("GET", r);
  const POST   = (r, c) => pedir("POST", r, c);
  const PATCH  = (r, c) => pedir("PATCH", r, c);
  const BORRAR = (r)    => pedir("DELETE", r);

  const esc = (s) => encodeURIComponent(s);

  /* =====================================================================
   *  API pública
   * =================================================================== */
  const db = {
    // Ya no hay configuración externa que pueda faltar: la base es local.
    configurado: true,

    /* ---------------- sesión ---------------- */
    auth: {
      async sesion() {
        try {
          const r = await GET("/auth/yo");
          return r && r.usuario ? r : null;
        } catch (e) {
          if (e.estado === 401) return null;
          throw e;
        }
      },
      async perfil() {
        try {
          const r = await GET("/auth/yo");
          return r ? r.usuario : null;
        } catch (e) {
          if (e.estado === 401) return null;
          throw e;
        }
      },
      async entrar(email, password) {
        const r = await POST("/auth/entrar", { email, password });
        return r.usuario;
      },
      async salir() {
        try { await POST("/auth/salir", {}); } catch (e) { /* igual se recarga */ }
      },
    },

    /* ---------------- prospectos ---------------- */
    leads: {
      listar()            { return GET("/leads"); },
      obtener(id)         { return GET("/leads/" + esc(id)); },
      crear(datos)        { return POST("/leads", datos); },
      actualizar(id, c)   { return PATCH("/leads/" + esc(id), c); },
      borrar(id)          { return BORRAR("/leads/" + esc(id)); },

      // El servidor crea la ficha de cliente y su esquema de pagos cuando la
      // etapa pasa a "ganado": aquí ya no hay que hacer nada aparte.
      moverEtapa(id, etapa) {
        return PATCH("/leads/" + esc(id), { etapa });
      },
    },

    /* ---------------- actividades ---------------- */
    actividades: {
      delLead(leadId) { return GET("/leads/" + esc(leadId) + "/actividades"); },
      agregar(leadId, titulo, detalle, tipo) {
        return POST("/leads/" + esc(leadId) + "/actividades", { titulo, detalle, tipo });
      },
    },

    /* ---------------- documentos ---------------- */
    documentos: {
      delLead(leadId) { return GET("/leads/" + esc(leadId) + "/documentos"); },
      guardar(leadId, tipo, payload, folio) {
        return POST("/documentos", { leadId, tipo, payload, folio });
      },
      async siguienteFolio(serie) {
        const r = await POST("/folios/siguiente", { serie: serie || "CA" });
        return r.folio;
      },
    },

    /* ---------------- recurrentes ---------------- */
    recurrentes: {
      listar() { return GET("/recurrentes"); },
    },

    /* ---------------- tareas ---------------- */
    tareas: {
      delDia()            { return GET("/tareas"); },
      alternar(id, hecha) { return PATCH("/tareas/" + esc(id), { done: !!hecha }); },
      crear(t)            { return POST("/tareas", t); },
    },

    /* ---------------- calendario ---------------- */
    eventos: {
      delMes(anio, mes) { return GET(`/eventos?anio=${anio}&mes=${mes}`); },
      crear(e)          { return POST("/eventos", e); },
    },

    /* ---------------- plantillas ---------------- */
    plantillas: {
      listar() { return GET("/plantillas"); },
      guardar(nombre, payload, alcance) {
        return POST("/plantillas", { nombre, payload, alcance });
      },
      async cargar(nombre) {
        const r = await GET("/plantillas/" + esc(nombre));
        return r ? r.payload : null;
      },
      borrar(nombre) { return BORRAR("/plantillas/" + esc(nombre)); },
    },

    /* ---------------- usuarios (solo admin) ---------------- */
    usuarios: {
      listar()   { return GET("/usuarios"); },
      crear(u)   { return POST("/usuarios", u); },
    },
  };

  window.db = db;
})();

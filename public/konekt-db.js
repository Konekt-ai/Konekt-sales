/* =====================================================================
 *  Konekt Sales · capa de datos
 *  ---------------------------------------------------------------
 *  Todo lo que toca la base de datos pasa por aquí. La interfaz de
 *  la app no sabe que existe Supabase: solo llama a db.leads.listar(),
 *  db.tareas.alternar(), etc.
 *
 *  Si algún día se cambia Supabase por otra cosa, se reescribe este
 *  archivo y la aplicación no se entera.
 *
 *  Seguridad: se usa la anon key y las políticas RLS de supabase/schema.sql.
 *  Un vendedor solo puede leer y escribir sus propios prospectos, y eso lo
 *  impone Postgres — no este archivo.
 * ===================================================================== */
(function () {
  "use strict";

  const cfg = window.KONEKT_CONFIG || {};
  const configurado =
    !!cfg.SUPABASE_URL &&
    !!cfg.SUPABASE_ANON_KEY &&
    !cfg.SUPABASE_URL.includes("xxxxxxxx");

  const sb = configurado
    ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
        auth: { persistSession: true, autoRefreshToken: true },
      })
    : null;

  /* ---------------- utilidades de formato ---------------- */
  const MESES = ["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"];

  // '2026-08-14' -> '14 Ago 2026'   (sin pasar por Date, para no correr un día por zona horaria)
  function fechaCorta(iso) {
    if (!iso) return "—";
    const [a, m, d] = String(iso).slice(0, 10).split("-");
    if (!a || !m || !d) return "—";
    return `${d} ${MESES[Number(m) - 1]} ${a}`;
  }
  function horaCorta(ts) {
    if (!ts) return "";
    const f = new Date(ts);
    return f.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit", hour12: false });
  }
  function hoyISO() {
    const f = new Date();
    return `${f.getFullYear()}-${String(f.getMonth() + 1).padStart(2, "0")}-${String(f.getDate()).padStart(2, "0")}`;
  }
  const uno = (v) => (Array.isArray(v) ? v[0] : v) || null;

  /* ---------------- traducción fila -> objeto de la app ---------------- */
  function mapPago(p) {
    return {
      n: p.concepto || `Pago ${p.numero}`,
      pct: Number(p.porcentaje),
      monto: Number(p.monto),
      estado: p.estado,
    };
  }

  function mapCliente(c) {
    if (!c) return undefined;
    return {
      id: c.id,
      fechaCierre: fechaCorta(c.fecha_cierre),
      servicio: c.servicio || "",
      precio: Number(c.precio),
      descuento: Number(c.descuento),
      iva: c.aplica_iva,
      formaPago: c.forma_pago || "",
      inicio: c.inicio || "Por definir",
      entrega: c.entrega || "Por definir",
      estado: c.estado || "Por iniciar",
      pagos: (c.pagos || []).sort((a, b) => a.numero - b.numero).map(mapPago),
    };
  }

  function mapLead(r) {
    const c = uno(r.clientes);
    return {
      id: r.id,
      nombre: r.nombre || "",
      empresa: r.empresa || "",
      giro: r.giro || "",
      tel: r.tel || "",
      email: r.email || "",
      fuente: r.fuente || "",
      entrada: fechaCorta(r.entrada),
      vendedor: (uno(r.perfiles) || {}).nombre || "",
      vendedorId: r.vendedor_id,
      servicio: r.servicio || "",
      necesidad: r.necesidad || "",
      etapa: r.etapa,
      valor: Number(r.valor) || 0,
      prob: Number(r.prob) || 0,
      interes: r.interes || "medio",
      proxAccion: r.prox_accion || "—",
      seguimiento: r.seguimiento ? fechaCorta(r.seguimiento) : "—",
      presupuesto: r.presupuesto || "No especificado",
      objecion: r.objecion || "—",
      notas: r.notas || "",
      ai: null, // Konekt AI real llega en la Fase 3
      timeline: [], // se carga bajo demanda al abrir la ficha
      docs: [],
      cliente: mapCliente(c),
    };
  }

  function mapTarea(t) {
    return {
      id: t.id,
      hora: horaCorta(t.vence_at),
      tx: t.titulo,
      prospecto: (uno(t.leads) || {}).nombre || "—",
      tipo: t.tipo,
      done: !!t.hecha_at,
      lead: t.lead_id,
    };
  }

  /* ---------------- errores legibles ---------------- */
  function revisar(res, queHacia) {
    if (res.error) {
      console.error(`[db] ${queHacia}:`, res.error);
      throw new Error(`${queHacia}: ${res.error.message}`);
    }
    return res.data;
  }

  /* =====================================================================
   *  API pública
   * ===================================================================== */
  const db = {
    configurado,
    cliente: sb,

    /* ---------------- sesión ---------------- */
    auth: {
      async sesion() {
        if (!sb) return null;
        const { data } = await sb.auth.getSession();
        return data.session || null;
      },
      async perfil() {
        if (!sb) return null;
        const { data: s } = await sb.auth.getSession();
        if (!s.session) return null;
        const res = await sb
          .from("perfiles")
          .select("id, nombre, rol, activo")
          .eq("id", s.session.user.id)
          .maybeSingle();
        if (res.error) {
          console.error("[db] perfil:", res.error);
          return { id: s.session.user.id, nombre: s.session.user.email, rol: "vendedor" };
        }
        return res.data || { id: s.session.user.id, nombre: s.session.user.email, rol: "vendedor" };
      },
      async entrar(email, password) {
        const res = await sb.auth.signInWithPassword({ email, password });
        if (res.error) throw new Error(traducirAuth(res.error.message));
        return res.data.session;
      },
      async salir() {
        if (sb) await sb.auth.signOut();
      },
      // Token de acceso para autenticarse contra nuestro propio backend (/api/*).
      // getSession() lo renueva solo si está por vencer.
      async token() {
        if (!sb) return null;
        const { data } = await sb.auth.getSession();
        return data.session ? data.session.access_token : null;
      },
      alCambiar(fn) {
        if (sb) sb.auth.onAuthStateChange((evento) => fn(evento));
      },
    },

    /* ---------------- prospectos ---------------- */
    leads: {
      async listar() {
        const res = await sb
          .from("leads")
          .select("*, perfiles(nombre), clientes(*, pagos(*))")
          .order("creado_at", { ascending: false });
        return revisar(res, "cargar prospectos").map(mapLead);
      },

      async crear(datos) {
        const res = await sb
          .from("leads")
          .insert({
            nombre: datos.nombre,
            empresa: datos.empresa || "",
            giro: datos.giro || "",
            tel: datos.tel || "",
            email: datos.email || "",
            fuente: datos.fuente || "Directo",
            servicio: datos.servicio || "",
            necesidad: datos.necesidad || "",
            etapa: datos.etapa || "nuevo",
            valor: Number(datos.valor) || 0,
            prob: Number(datos.prob) || 0,
            interes: datos.interes || "medio",
            prox_accion: datos.proxAccion || "",
            seguimiento: datos.seguimiento || null,
            presupuesto: datos.presupuesto || "",
            notas: datos.notas || "",
            entrada: hoyISO(),
          })
          .select("*, perfiles(nombre), clientes(*, pagos(*))")
          .single();
        return mapLead(revisar(res, "crear prospecto"));
      },

      async actualizar(id, cambios) {
        const res = await sb
          .from("leads")
          .update(cambios)
          .eq("id", id)
          .select("*, perfiles(nombre), clientes(*, pagos(*))")
          .single();
        return mapLead(revisar(res, "actualizar prospecto"));
      },

      // Mover de etapa. Si cae en "ganado" y aún no tiene ficha de cliente,
      // se crea con el esquema de pagos 50/30/20 por omisión.
      async moverEtapa(id, etapa, leadEnMemoria) {
        const actualizado = await db.leads.actualizar(id, { etapa });
        if (etapa === "ganado" && !actualizado.cliente) {
          await db.clientes.crearDesdeLead(leadEnMemoria || actualizado);
          return db.leads.obtener(id);
        }
        return actualizado;
      },

      async obtener(id) {
        const res = await sb
          .from("leads")
          .select("*, perfiles(nombre), clientes(*, pagos(*))")
          .eq("id", id)
          .single();
        return mapLead(revisar(res, "cargar prospecto"));
      },

      async borrar(id) {
        const res = await sb.from("leads").delete().eq("id", id);
        revisar(res, "borrar prospecto");
      },
    },

    /* ---------------- actividades (timeline de la ficha) ---------------- */
    actividades: {
      async delLead(leadId) {
        const res = await sb
          .from("actividades")
          .select("*")
          .eq("lead_id", leadId)
          .order("ocurrio_at", { ascending: true });
        return revisar(res, "cargar actividades").map((a) => ({
          dt: fechaCorta(a.ocurrio_at),
          tx: a.titulo,
          sub: a.detalle || "",
          cls: a.tipo === "sistema" ? "mut" : "",
        }));
      },
      async agregar(leadId, titulo, detalle, tipo) {
        const res = await sb
          .from("actividades")
          .insert({ lead_id: leadId, titulo, detalle: detalle || "", tipo: tipo || "nota" })
          .select()
          .single();
        return revisar(res, "registrar actividad");
      },
    },

    /* ---------------- documentos generados ---------------- */
    documentos: {
      async delLead(leadId) {
        const res = await sb
          .from("documentos")
          .select("id, tipo, folio, creado_at")
          .eq("lead_id", leadId)
          .order("creado_at", { ascending: false });
        return revisar(res, "cargar documentos").map((d) => ({
          t: d.tipo === "propuesta" ? "Propuesta comercial" : `Cotización ${d.folio || ""}`.trim(),
          d: fechaCorta(d.creado_at),
        }));
      },
      async guardar(leadId, tipo, payload, folio) {
        const res = await sb
          .from("documentos")
          .insert({ lead_id: leadId || null, tipo, payload, folio: folio || null })
          .select()
          .single();
        return revisar(res, "guardar documento");
      },
      async siguienteFolio(serie) {
        const res = await sb.rpc("siguiente_folio", { p_serie: serie || "CA" });
        return revisar(res, "generar folio");
      },
    },

    /* ---------------- clientes ---------------- */
    clientes: {
      async crearDesdeLead(lead) {
        const iva = lead.valor * 0.16;
        const total = lead.valor + iva;
        const p1 = Math.round(total * 0.5);
        const p2 = Math.round(total * 0.3);

        const cli = revisar(
          await sb
            .from("clientes")
            .insert({
              lead_id: lead.id,
              servicio: lead.servicio || "",
              precio: lead.valor,
              forma_pago: "50% / 30% / 20%",
            })
            .select()
            .single(),
          "crear ficha de cliente"
        );

        revisar(
          await sb.from("pagos").insert([
            { cliente_id: cli.id, numero: 1, concepto: "Pago 1", porcentaje: 50, monto: p1 },
            { cliente_id: cli.id, numero: 2, concepto: "Pago 2", porcentaje: 30, monto: p2 },
            { cliente_id: cli.id, numero: 3, concepto: "Pago 3", porcentaje: 20, monto: total - p1 - p2 },
          ]),
          "crear esquema de pagos"
        );
        return cli;
      },
    },

    /* ---------------- servicios recurrentes ---------------- */
    recurrentes: {
      async listar() {
        const res = await sb
          .from("recurrentes")
          .select("*, clientes(lead_id, leads(empresa))")
          .order("prox_cobro", { ascending: true });
        return revisar(res, "cargar recurrentes").map((r) => {
          const cli = uno(r.clientes) || {};
          return {
            empresa: ((uno(cli.leads) || {}).empresa) || "—",
            servicio: r.servicio,
            mensualidad: Number(r.mensualidad),
            proxCobro: fechaCorta(r.prox_cobro),
            ultimo: fechaCorta(r.ultimo_cobro),
            estado: r.estado,
            renovacion: r.renovacion,
            contrato: r.contrato,
          };
        });
      },
    },

    /* ---------------- tareas ---------------- */
    tareas: {
      async delDia() {
        const inicio = hoyISO() + "T00:00:00";
        const fin = hoyISO() + "T23:59:59";
        const res = await sb
          .from("tareas")
          .select("*, leads(nombre)")
          .gte("vence_at", inicio)
          .lte("vence_at", fin)
          .order("vence_at", { ascending: true });
        return revisar(res, "cargar tareas").map(mapTarea);
      },
      async alternar(id, hecha) {
        const res = await sb
          .from("tareas")
          .update({ hecha_at: hecha ? new Date().toISOString() : null })
          .eq("id", id);
        revisar(res, "actualizar tarea");
      },
      async crear({ titulo, tipo, venceAt, leadId }) {
        const res = await sb
          .from("tareas")
          .insert({ titulo, tipo: tipo || "task", vence_at: venceAt, lead_id: leadId || null })
          .select("*, leads(nombre)")
          .single();
        return mapTarea(revisar(res, "crear tarea"));
      },
    },

    /* ---------------- calendario ---------------- */
    eventos: {
      // Devuelve { 14: [{t,x}], 16: [...] } para el mes indicado.
      async delMes(anio, mes /* 1-12 */) {
        const inicio = `${anio}-${String(mes).padStart(2, "0")}-01T00:00:00`;
        const finMes = new Date(anio, mes, 0).getDate();
        const fin = `${anio}-${String(mes).padStart(2, "0")}-${finMes}T23:59:59`;
        const res = await sb
          .from("eventos")
          .select("*")
          .gte("inicio", inicio)
          .lte("inicio", fin)
          .order("inicio", { ascending: true });
        const porDia = {};
        for (const e of revisar(res, "cargar calendario")) {
          const dia = new Date(e.inicio).getDate();
          (porDia[dia] = porDia[dia] || []).push({ t: e.tipo, x: e.titulo, hora: horaCorta(e.inicio) });
        }
        return porDia;
      },
      async crear({ titulo, tipo, inicio, leadId }) {
        const res = await sb
          .from("eventos")
          .insert({ titulo, tipo: tipo || "call", inicio, lead_id: leadId || null })
          .select()
          .single();
        return revisar(res, "crear evento");
      },
    },

    /* ---------------- plantillas del generador ---------------- */
    plantillas: {
      async listar() {
        const res = await sb.from("plantillas").select("id, nombre, alcance").order("nombre");
        return revisar(res, "cargar plantillas");
      },
      async guardar(nombre, payload, alcance) {
        const res = await sb
          .from("plantillas")
          .upsert(
            { nombre, payload, alcance: alcance || "personal", dueno_id: (await sb.auth.getUser()).data.user.id },
            { onConflict: "dueno_id,nombre" }
          )
          .select()
          .single();
        return revisar(res, "guardar plantilla");
      },
      async cargar(nombre) {
        const res = await sb.from("plantillas").select("payload").eq("nombre", nombre).limit(1).maybeSingle();
        const fila = revisar(res, "cargar plantilla");
        return fila ? fila.payload : null;
      },
      async borrar(nombre) {
        const res = await sb.from("plantillas").delete().eq("nombre", nombre);
        revisar(res, "borrar plantilla");
      },
    },
  };

  function traducirAuth(msg) {
    const m = String(msg).toLowerCase();
    if (m.includes("invalid login credentials")) return "Correo o contraseña incorrectos.";
    if (m.includes("email not confirmed")) return "Falta confirmar el correo desde la liga que te llegó.";
    if (m.includes("failed to fetch")) return "No se pudo conectar con Supabase. Revisa la URL en konekt-config.js.";
    return msg;
  }

  window.db = db;
})();

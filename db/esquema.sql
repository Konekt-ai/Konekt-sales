-- =====================================================================
--  Konekt Sales · esquema SQLite
--  Se aplica solo al arrancar el servidor (db/index.js).
--  Todo es CREATE ... IF NOT EXISTS: correrlo de nuevo no rompe nada.
--
--  Diferencias contra el esquema anterior de Supabase:
--    - No hay RLS. El alcance por vendedor lo impone la API (rutas/api.js).
--    - No hay auth.users. Los usuarios y las sesiones viven aquí.
--    - Los uuid los genera la aplicación con crypto.randomUUID().
--    - Las fechas son texto ISO-8601. SQLite no tiene tipo fecha.
--    - jsonb pasa a TEXT con JSON serializado.
-- =====================================================================

-- ---------------------------------------------------------------------
--  USUARIOS Y SESIONES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuarios (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE COLLATE NOCASE,
  password_hash TEXT NOT NULL,          -- scrypt: sal:hash, ver db/auth.js
  nombre        TEXT NOT NULL DEFAULT '',
  rol           TEXT NOT NULL DEFAULT 'vendedor'
                CHECK (rol IN ('vendedor','gerente','admin')),
  activo        INTEGER NOT NULL DEFAULT 1,
  creado_at     TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sesiones (
  token       TEXT PRIMARY KEY,         -- aleatorio de 32 bytes, va en la cookie
  usuario_id  TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  creada_at   TEXT NOT NULL DEFAULT (datetime('now')),
  expira_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sesiones_usuario_idx ON sesiones(usuario_id);
CREATE INDEX IF NOT EXISTS sesiones_expira_idx  ON sesiones(expira_at);

-- ---------------------------------------------------------------------
--  PROSPECTOS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
  id             TEXT PRIMARY KEY,
  vendedor_id    TEXT NOT NULL REFERENCES usuarios(id),
  nombre         TEXT NOT NULL,
  empresa        TEXT NOT NULL DEFAULT '',
  giro           TEXT DEFAULT '',
  tel            TEXT DEFAULT '',
  email          TEXT DEFAULT '',
  fuente         TEXT DEFAULT 'Directo',
  servicio       TEXT DEFAULT '',
  necesidad      TEXT DEFAULT '',
  etapa          TEXT NOT NULL DEFAULT 'nuevo'
                 CHECK (etapa IN ('nuevo','contactado','calificado','cotizacion','negociacion','ganado','perdido')),
  valor          REAL NOT NULL DEFAULT 0,
  prob           INTEGER NOT NULL DEFAULT 0 CHECK (prob BETWEEN 0 AND 100),
  interes        TEXT DEFAULT 'medio' CHECK (interes IN ('alto','medio','bajo')),
  prox_accion    TEXT DEFAULT '',
  seguimiento    TEXT,                  -- fecha ISO 'YYYY-MM-DD'
  presupuesto    TEXT DEFAULT '',
  objecion       TEXT DEFAULT '',
  notas          TEXT DEFAULT '',
  entrada        TEXT NOT NULL DEFAULT (date('now')),
  creado_at      TEXT NOT NULL DEFAULT (datetime('now')),
  actualizado_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS leads_vendedor_idx ON leads(vendedor_id);
CREATE INDEX IF NOT EXISTS leads_etapa_idx    ON leads(etapa);
CREATE INDEX IF NOT EXISTS leads_seguim_idx   ON leads(seguimiento);

-- Mantiene actualizado_at sin que la aplicación tenga que acordarse.
CREATE TRIGGER IF NOT EXISTS leads_touch
AFTER UPDATE ON leads
FOR EACH ROW
WHEN NEW.actualizado_at = OLD.actualizado_at
BEGIN
  UPDATE leads SET actualizado_at = datetime('now') WHERE id = NEW.id;
END;

-- ---------------------------------------------------------------------
--  HISTORIAL DE ETAPAS
--  Sin esto el panel del admin no puede medir nada real.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_etapa_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  lead_id       TEXT NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  etapa_origen  TEXT,
  etapa_destino TEXT NOT NULL,
  usuario_id    TEXT REFERENCES usuarios(id),
  creado_at     TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS etapa_log_lead_idx ON lead_etapa_log(lead_id, creado_at DESC);

-- Cada cambio de etapa se registra solo, venga de donde venga.
CREATE TRIGGER IF NOT EXISTS leads_etapa_alta
AFTER INSERT ON leads
FOR EACH ROW
BEGIN
  INSERT INTO lead_etapa_log (lead_id, etapa_origen, etapa_destino, usuario_id)
  VALUES (NEW.id, NULL, NEW.etapa, NEW.vendedor_id);
END;

CREATE TRIGGER IF NOT EXISTS leads_etapa_cambio
AFTER UPDATE OF etapa ON leads
FOR EACH ROW
WHEN NEW.etapa <> OLD.etapa
BEGIN
  INSERT INTO lead_etapa_log (lead_id, etapa_origen, etapa_destino, usuario_id)
  VALUES (NEW.id, OLD.etapa, NEW.etapa, NEW.vendedor_id);
END;

-- ---------------------------------------------------------------------
--  ACTIVIDADES  (el timeline de la ficha)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS actividades (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  lead_id     TEXT NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  usuario_id  TEXT REFERENCES usuarios(id),
  titulo      TEXT NOT NULL,
  detalle     TEXT DEFAULT '',
  tipo        TEXT DEFAULT 'nota'
              CHECK (tipo IN ('nota','llamada','correo','whatsapp','reunion','demo','propuesta','sistema')),
  ocurrio_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS actividades_lead_idx ON actividades(lead_id, ocurrio_at);

-- ---------------------------------------------------------------------
--  CLIENTES, PAGOS Y RECURRENTES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clientes (
  id           TEXT PRIMARY KEY,
  lead_id      TEXT NOT NULL UNIQUE REFERENCES leads(id) ON DELETE CASCADE,
  fecha_cierre TEXT NOT NULL DEFAULT (date('now')),
  servicio     TEXT DEFAULT '',
  precio       REAL NOT NULL DEFAULT 0,
  descuento    REAL NOT NULL DEFAULT 0,
  aplica_iva   INTEGER NOT NULL DEFAULT 1,
  forma_pago   TEXT DEFAULT '',
  inicio       TEXT DEFAULT 'Por definir',
  entrega      TEXT DEFAULT 'Por definir',
  estado       TEXT DEFAULT 'Por iniciar'
               CHECK (estado IN ('Por iniciar','En desarrollo','En pruebas','Entregado','Pausado')),
  creado_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS pagos (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  cliente_id TEXT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  numero     INTEGER NOT NULL,
  concepto   TEXT DEFAULT '',
  porcentaje REAL NOT NULL DEFAULT 0,
  monto      REAL NOT NULL DEFAULT 0,
  estado     TEXT NOT NULL DEFAULT 'pend' CHECK (estado IN ('pend','ok','vencido')),
  vence_at   TEXT,
  pagado_at  TEXT,
  UNIQUE (cliente_id, numero)
);

CREATE TABLE IF NOT EXISTS recurrentes (
  id           TEXT PRIMARY KEY,
  cliente_id   TEXT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  servicio     TEXT NOT NULL DEFAULT '',
  mensualidad  REAL NOT NULL DEFAULT 0,
  renovacion   TEXT DEFAULT 'Mensual' CHECK (renovacion IN ('Mensual','Trimestral','Anual')),
  prox_cobro   TEXT,
  ultimo_cobro TEXT,
  estado       TEXT DEFAULT 'ok' CHECK (estado IN ('ok','pendiente','cancelado')),
  contrato     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS recurrentes_cliente_idx ON recurrentes(cliente_id);

-- ---------------------------------------------------------------------
--  DOCUMENTOS, FOLIOS Y PLANTILLAS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS folios (
  serie       TEXT PRIMARY KEY,
  consecutivo INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO folios (serie, consecutivo) VALUES ('CA', 0);

CREATE TABLE IF NOT EXISTS documentos (
  id         TEXT PRIMARY KEY,
  lead_id    TEXT REFERENCES leads(id) ON DELETE CASCADE,
  tipo       TEXT NOT NULL CHECK (tipo IN ('propuesta','cotizacion')),
  folio      TEXT,
  version    INTEGER NOT NULL DEFAULT 1,
  payload    TEXT NOT NULL,             -- el objeto `state` del generador, en JSON
  pdf_ruta   TEXT,
  creado_por TEXT REFERENCES usuarios(id),
  creado_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS documentos_lead_idx ON documentos(lead_id, creado_at DESC);

CREATE TABLE IF NOT EXISTS plantillas (
  id        TEXT PRIMARY KEY,
  nombre    TEXT NOT NULL,
  alcance   TEXT NOT NULL DEFAULT 'personal' CHECK (alcance IN ('personal','equipo')),
  payload   TEXT NOT NULL,
  dueno_id  TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  creado_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (dueno_id, nombre)
);

-- ---------------------------------------------------------------------
--  TAREAS Y CALENDARIO
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tareas (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  usuario_id TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  lead_id    TEXT REFERENCES leads(id) ON DELETE SET NULL,
  titulo     TEXT NOT NULL,
  tipo       TEXT NOT NULL DEFAULT 'task' CHECK (tipo IN ('call','demo','follow','task')),
  vence_at   TEXT NOT NULL,             -- ISO completo 'YYYY-MM-DDTHH:MM'
  hecha_at   TEXT,
  creado_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS tareas_usuario_idx ON tareas(usuario_id, vence_at);

CREATE TABLE IF NOT EXISTS eventos (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  usuario_id TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  lead_id    TEXT REFERENCES leads(id) ON DELETE SET NULL,
  titulo     TEXT NOT NULL,
  tipo       TEXT NOT NULL DEFAULT 'call' CHECK (tipo IN ('call','demo','follow','pay')),
  inicio     TEXT NOT NULL,
  fin        TEXT,
  creado_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS eventos_usuario_idx ON eventos(usuario_id, inicio);

-- ---------------------------------------------------------------------
--  KONEKT AI  (caché por contenido, para no pagar dos veces lo mismo)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_insights (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  lead_id      TEXT NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  resumen      TEXT DEFAULT '',
  interes      TEXT DEFAULT '',
  intencion    TEXT DEFAULT '',
  objecion     TEXT DEFAULT '',
  presupuesto  TEXT DEFAULT '',
  accion       TEXT DEFAULT '',
  prob         INTEGER,
  modelo       TEXT,
  hash_entrada TEXT NOT NULL,
  generado_at  TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (lead_id, hash_entrada)
);

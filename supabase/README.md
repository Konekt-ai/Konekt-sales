# Conectar Supabase

Konekt Sales ya no trae datos dentro del código. Todo sale de Supabase.
Estos son los pasos, en orden. Toma unos 10 minutos.

## 1 · Crear el proyecto

En <https://supabase.com> → **New project**. Anota la contraseña de la base de
datos que te pida (no la vas a necesitar para esto, pero sí después).

## 2 · Crear las tablas

Ve a **SQL Editor** → **New query**, pega **todo** el contenido de
[`schema.sql`](schema.sql) y dale **Run**.

Se puede volver a ejecutar las veces que quieras: no borra datos ni truena si
las tablas ya existen.

Esto crea las tablas, los índices, los disparadores y —lo más importante— las
**políticas RLS**: las reglas que hacen que un vendedor solo pueda leer y
escribir sus propios prospectos. Esas reglas viven dentro de Postgres, así que
se cumplen aunque alguien intente saltarse la interfaz.

## 3 · Crear tu usuario

**Authentication** → **Users** → **Add user** → *Create new user*.
Pon tu correo y una contraseña, y activa **Auto Confirm User** para no tener que
confirmar por correo.

Regresa al **SQL Editor** y date el rol de administrador:

```sql
update public.perfiles
   set rol = 'admin', nombre = 'Tu Nombre'
 where id = (select id from auth.users where email = 'tu@correo.com');
```

Roles disponibles:

| Rol        | Qué puede hacer                                     |
| ---------- | --------------------------------------------------- |
| `vendedor` | Ver y editar únicamente sus propios prospectos       |
| `gerente`  | Ver y editar los prospectos de todo el equipo        |
| `admin`    | Todo lo anterior, más borrar                         |

Los vendedores que registres después quedan como `vendedor` automáticamente.

## 4 · Conectar la aplicación

En **Project Settings** → **API** copia dos valores:

- **Project URL**
- **anon public** key

Luego, en la carpeta `public/`:

```
copy konekt-config.example.js konekt-config.js
```

y pega ahí los dos valores.

> La anon key está pensada para vivir en el navegador: no es un secreto.
> Quien protege los datos son las políticas RLS del paso 2.
> La que **nunca** debe salir del servidor es la `service_role` key.

## 5 · Arrancar

```
npm start
```

Abre <http://localhost:3000>, entra con tu correo y contraseña, y registra tu
primer prospecto con el botón **Nuevo prospecto**.

---

## Qué quedó guardado en la base

| Tabla            | Para qué                                                    |
| ---------------- | ----------------------------------------------------------- |
| `perfiles`       | Nombre y rol de cada usuario                                 |
| `leads`          | Prospectos                                                   |
| `lead_etapa_log` | Cada cambio de etapa, con quién y cuándo                     |
| `actividades`    | El timeline de la ficha                                      |
| `clientes`       | Un lead ganado convertido en proyecto                        |
| `pagos`          | Esquema de pagos de cada proyecto                            |
| `recurrentes`    | Mensualidades de soporte, hosting y mantenimiento            |
| `documentos`     | Propuestas y cotizaciones generadas, versionadas             |
| `folios`         | Consecutivo de cotizaciones (CA-001, CA-002…)                |
| `plantillas`     | Plantillas del generador, personales o compartidas al equipo |
| `tareas`         | Pendientes de Mi día                                         |
| `eventos`        | Calendario                                                   |
| `ai_insights`    | Caché de los análisis de Konekt AI (Fase 3)                  |

## Comprobar que RLS funciona

Vale la pena verificarlo antes de dar de alta al equipo:

1. Crea un segundo usuario con rol `vendedor`.
2. Con tu usuario admin, registra un prospecto.
3. Entra con el segundo usuario: **no debe verlo**.
4. Registra un prospecto con el segundo usuario.
5. Vuelve a entrar como admin: **debes ver los dos**.

Si el vendedor ve prospectos ajenos, revisa que su fila en `perfiles` tenga
`rol = 'vendedor'` y que el paso 2 haya corrido completo.

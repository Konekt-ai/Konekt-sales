# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------
#  Konekt Sales
#  Imagen chica y sin herramientas de compilación en la capa final.
# ---------------------------------------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app
# Se copian solo los manifiestos primero: mientras no cambien, Docker reutiliza
# la capa de node_modules y la reconstrucción es de segundos.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0

# tini se encarga de reenviar las señales y de recoger procesos zombis, para
# que el SIGTERM de "docker stop" llegue de verdad al cierre ordenado de Node.
RUN apk add --no-cache tini wget

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY server.js ./
COPY db ./db
COPY rutas ./rutas
COPY scripts ./scripts
COPY public ./public

# Carpetas de datos, con dueño node: el proceso no corre como root.
RUN mkdir -p /app/datos /app/respaldos && chown -R node:node /app/datos /app/respaldos

# Nunca correr como root dentro del contenedor.
USER node

EXPOSE 3000

# Docker reinicia el contenedor si esto falla de forma sostenida.
# /api/health responde 503 mientras falte configuración.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]

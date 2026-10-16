# ---- Stage 1: build the React app with Node ----
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Stage 2: serve the static build with unprivileged Nginx ----
FROM nginxinc/nginx-unprivileged:1.27-alpine

USER root
RUN apk upgrade --no-cache
USER 101

# Default upstream for docker compose; overridden in Kubernetes via env
ENV BACKEND_URL=http://backend:8000
ENV NGINX_ENVSUBST_FILTER=BACKEND_URL

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build --chown=101:101 /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

# Stage 1 — build the static Vite bundle
FROM node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# Stage 2 — serve it with Nginx
FROM nginx:1.27-alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Defaults match the service names used in docker-compose.yml; override at
# `docker run`/k8s level if the backend hostnames differ.
ENV AUTH_SERVICE_HOST=auth-service \
    AUTH_SERVICE_PORT=5001 \
    CATALOG_SERVICE_HOST=catalog-service \
    CATALOG_SERVICE_PORT=5002 \
    ORDERS_SERVICE_HOST=orders-service \
    ORDERS_SERVICE_PORT=5003

EXPOSE 80

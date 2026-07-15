# ---- build stage: compile the SPA ----
FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# apiBaseUrl must be correct in environment.production.ts BEFORE this runs (§14.5)
RUN npm run build   # == `ng build`, defaultConfiguration=production

# ---- final stage: serve static files via nginx ----
FROM nginx:1.27-alpine AS final
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/frontend/browser /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]

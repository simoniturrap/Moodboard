# Moodboard Sync (Cloudflare Worker)

Backend de sincronización: guarda el estado **actual** de la biblioteca de Moodboard
(`library.json`, incluida la papelera) en **D1**, y las imágenes en **R2**. Gratis para
este uso (R2: 10 GB sin coste de descarga; D1: 5 GB).

## Puesta en marcha (una sola vez)

Necesitas una cuenta de Cloudflare (gratis). Desde esta carpeta:

```bash
cd server
npm install

# 1. Iniciar sesión en Cloudflare
npx wrangler login

# 2. Crear la base de datos D1 y copiar el database_id a wrangler.jsonc
npx wrangler d1 create moodboard

# 3. Crear el bucket R2 para las imágenes
npx wrangler r2 bucket create moodboard-media

# 4. Aplicar el esquema a D1 (remoto)
npx wrangler d1 execute moodboard --remote --file=./schema.sql

# 5. Definir el token secreto (invéntate uno largo y aleatorio; lo pegarás también en la app)
npx wrangler secret put SYNC_TOKEN

# 6. Desplegar
npx wrangler deploy
```

Al desplegar verás la URL del Worker, p. ej.
`https://moodboard-sync.tu-subdominio.workers.dev`.
Esa URL y el token son lo que se pega en la app, en **Moodboard → Sincronización…**.

## Carga inicial opcional

La app sube todo sola la primera vez que se configura. Si prefieres hacerlo a mano:

```bash
WORKER_URL="https://moodboard-sync.tu-subdominio.workers.dev" \
SYNC_TOKEN="tu-token" \
./seed.sh
```

## Prueba rápida

```bash
curl -s https://.../library -H "Authorization: Bearer tu-token"      # 404 al inicio
```

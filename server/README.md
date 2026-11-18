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

```bash
# 7. Crear tu cuenta (email + contraseña) con la que iniciarás sesión en la app.
#    El token autoriza este alta; la contraseña se guarda derivada con PBKDF2, nunca en claro.
curl -s -X POST https://moodboard-sync.tu-subdominio.workers.dev/auth/setup \
  -H "Authorization: Bearer tu-token" \
  -H "Content-Type: application/json" \
  -d '{"email":"tu@email.com","password":"tu-contraseña"}'
# -> {"ok":true}
```

En la app, en **Moodboard → Sincronización…**, pegas la URL del Worker e inicias sesión con
ese email y contraseña (el token queda por debajo, no hace falta teclearlo).

## Cuenta y login

Una sola cuenta (uso personal). La contraseña vive en la tabla `auth` de D1, derivada con
PBKDF2-SHA256; el Worker nunca la guarda ni la devuelve en claro.

```
POST /login        <- { email, password }  -> { token }        (público; valida y entrega el token)
POST /auth/setup   <- { email, password }  -> { ok: true }     (requiere el token; fija o cambia la cuenta)
```

Para **cambiar la contraseña**, repite el paso 7 con la nueva. Si la olvidas, igual: el token
(en tu Llavero / como secreto del Worker) es lo que autoriza el cambio.

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

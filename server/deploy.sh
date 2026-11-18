#!/usr/bin/env bash
# Despliega tu PROPIO backend de Moodboard en tu cuenta de Cloudflare, en un solo comando.
# Crea la base D1, el bucket R2, aplica el esquema, fija un token y publica el Worker.
#
#   cd server && ./deploy.sh
#
# Requisitos: una cuenta de Cloudflare (gratis) y Node instalado. Todo lo demás lo baja npx.
# Al terminar imprime la URL del Worker y el token de configuración: con esos datos te
# registras desde la app (pestaña "Registrarse").
set -euo pipefail
cd "$(dirname "$0")"

uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

echo "▸ 1/6 Iniciar sesión en Cloudflare…"
npx wrangler login

echo "▸ 2/6 Crear la base de datos D1 'moodboard'…"
create_out="$(npx wrangler d1 create moodboard 2>&1 || true)"
echo "$create_out"
db_id="$(printf '%s' "$create_out" | grep -oE "$uuid_re" | head -1 || true)"
if [ -z "$db_id" ]; then
  echo "  (no se detectó el id en la salida; probablemente ya existía — lo busco)"
  db_id="$(npx wrangler d1 info moodboard 2>/dev/null | grep -oE "$uuid_re" | head -1 || true)"
fi
[ -n "$db_id" ] || { echo "✗ No pude obtener el database_id. Créala a mano y pégalo en wrangler.jsonc."; exit 1; }
echo "  database_id = $db_id"

echo "▸ 3/6 Escribir el database_id en wrangler.jsonc…"
sed -i '' -E "s/(\"database_id\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1$db_id\2/" wrangler.jsonc

echo "▸ 4/6 Crear el bucket R2 'moodboard-media'…"
npx wrangler r2 bucket create moodboard-media 2>&1 || echo "  (ya existía, sigo)"

echo "▸ 5/6 Aplicar el esquema a D1…"
npx wrangler d1 execute moodboard --remote --file=./schema.sql

echo "▸ 6/6 Fijar el token de sincronización y desplegar…"
token="$(openssl rand -hex 24)"
printf '%s' "$token" | npx wrangler secret put SYNC_TOKEN
deploy_out="$(npx wrangler deploy 2>&1)"
echo "$deploy_out"
worker_url="$(printf '%s' "$deploy_out" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1 || true)"

echo
echo "────────────────────────────────────────────────────────────"
echo "✓ Backend desplegado."
echo
echo "En la app → pestaña \"Registrarse\":"
echo "   Servidor:                ${worker_url:-<la URL https://…workers.dev de arriba>}"
echo "   Token de configuración:  $token"
echo "   Email y contraseña:      los que quieras"
echo
echo "Guarda el token: sólo hace falta para registrarte o cambiar la contraseña."
echo "────────────────────────────────────────────────────────────"

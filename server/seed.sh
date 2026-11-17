#!/usr/bin/env bash
# Sube de una vez el estado local actual de Moodboard al Worker:
#   el library.json (como revisión inicial) y todas las imágenes referenciadas.
#
# Uso:
#   WORKER_URL="https://moodboard-sync.tu-subdominio.workers.dev" \
#   SYNC_TOKEN="tu-token" \
#   ./seed.sh
#
# Normalmente NO hace falta: la app sube todo sola en el primer arranque ya
# configurada. Este script sirve para la carga inicial o para pruebas.
set -euo pipefail

: "${WORKER_URL:?Define WORKER_URL}"
: "${SYNC_TOKEN:?Define SYNC_TOKEN}"

DATA_DIR="$HOME/Library/Application Support/Moodboard"
LIB="$DATA_DIR/library.json"
MEDIA="$DATA_DIR/Media"

[ -f "$LIB" ] || { echo "No encuentro $LIB"; exit 1; }

echo "Subiendo library.json…"
python3 - "$LIB" "$WORKER_URL" "$SYNC_TOKEN" <<'PY'
import json, sys, urllib.request
lib_path, base, token = sys.argv[1], sys.argv[2].rstrip('/'), sys.argv[3]
raw = open(lib_path, 'r', encoding='utf-8').read()
body = json.dumps({"baseRevision": 0, "json": raw}).encode()
req = urllib.request.Request(f"{base}/library", data=body, method="PUT",
                            headers={"Authorization": f"Bearer {token}",
                                     "Content-Type": "application/json"})
with urllib.request.urlopen(req) as r:
    print("  ->", r.status, r.read().decode())
PY

echo "Subiendo imágenes referenciadas…"
python3 - "$LIB" "$MEDIA" "$WORKER_URL" "$SYNC_TOKEN" <<'PY'
import json, os, sys, urllib.request
lib_path, media, base, token = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/'), sys.argv[4]
d = json.load(open(lib_path, encoding='utf-8'))
names = set()
def collect(items):
    for it in items:
        if it.get("media"): names.add(it["media"])
for b in d.get("boards", []):
    collect(b.get("items", []))
for t in d.get("trash", []):
    c = t.get("content", {})
    if "board" in c: collect(c["board"].get("items", []))
    if "item" in c and isinstance(c["item"], list) and c["item"] and isinstance(c["item"][0], dict):
        if c["item"][0].get("media"): names.add(c["item"][0]["media"])
ok = skip = 0
for name in sorted(names):
    path = os.path.join(media, name)
    if not os.path.exists(path):
        skip += 1; continue
    # HEAD: no re-subir lo que ya está.
    head = urllib.request.Request(f"{base}/media/{name}", method="HEAD",
                                  headers={"Authorization": f"Bearer {token}"})
    try:
        urllib.request.urlopen(head); continue
    except urllib.error.HTTPError as e:
        if e.code != 404: raise
    data = open(path, "rb").read()
    put = urllib.request.Request(f"{base}/media/{name}", data=data, method="PUT",
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/octet-stream"})
    urllib.request.urlopen(put); ok += 1
    print("  subida", name)
print(f"Hecho. Subidas: {ok}. Faltaban en disco: {skip}.")
PY

echo "Listo."

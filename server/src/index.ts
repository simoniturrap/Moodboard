/**
 * Moodboard Sync Worker.
 *
 * API REST mínima para sincronizar la biblioteca de Moodboard entre los equipos
 * de un mismo usuario. Protegida por un token compartido (secreto SYNC_TOKEN).
 *
 *   GET    /library            -> { revision, json }  | 404 si aún no hay nada
 *   PUT    /library            <- { baseRevision, json }
 *                                 200 { revision } si baseRevision coincide (o primer push)
 *                                 409 { revision, json } si hay una versión más nueva
 *   HEAD   /media/:name        -> 200 | 404
 *   GET    /media/:name        -> bytes de la imagen | 404
 *   PUT    /media/:name        <- bytes de la imagen (idempotente)
 *   DELETE /media/:name        -> borra la imagen de R2 (idempotente)
 *   GET    /media              -> { keys: [name, ...] }
 *   GET    /usage              -> { count, bytes }  (almacenamiento usado en R2)
 *
 * Compartir (autenticado):
 *   POST   /share              <- { boardId }  -> { token }   (idempotente por tablero)
 *   GET    /share/:boardId     -> { token } | 404
 *   DELETE /share/:boardId     -> borra el enlace (idempotente)
 *
 * Visor público (SIN token, cualquiera con el link):
 *   GET    /s/:token           -> página HTML del visor
 *   GET    /s/:token/data      -> { name, items } del tablero, en vivo desde `library`
 *   GET    /s/:token/media/:n  -> bytes de una imagen referenciada por el tablero
 */

export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  SYNC_TOKEN: string;
}

const LIBRARY_ID = "default";

const json = (data: unknown, status = 200): Response =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

const text = (body: string, status: number): Response =>
  new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

/** Comparación en tiempo constante para no filtrar el token por timing. */
function tokenMatches(provided: string, expected: string): boolean {
  if (provided.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < provided.length; i++) diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

function authorized(request: Request, env: Env): boolean {
  if (!env.SYNC_TOKEN) return false;
  const header = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  if (!header.startsWith(prefix)) return false;
  return tokenMatches(header.slice(prefix.length), env.SYNC_TOKEN);
}

/** Nombre de archivo de media seguro: UUID.ext, sin rutas ni trucos. */
function safeMediaName(name: string): string | null {
  const decoded = decodeURIComponent(name);
  return /^[A-Za-z0-9._-]+$/.test(decoded) && !decoded.includes("..") ? decoded : null;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);
    const method = request.method.toUpperCase();

    try {
      // ---- Visor público /s/... (sin token) ----------------------------
      if (segments[0] === "s") {
        const token = segments[1];
        if (!token) return text("Not found", 404);
        if (method === "GET" && segments.length === 2) {
          return serveViewer(url.origin, env, token);
        }
        if (method === "GET" && segments.length === 3 && segments[2] === "data") {
          return getSharedData(env, token);
        }
        if ((method === "GET" || method === "HEAD") && segments.length === 4 && segments[2] === "media") {
          return getSharedMedia(env, token, segments[3], method);
        }
        return text("Not found", 404);
      }

      // ---- Fuentes públicas /fonts/:name (webfonts de autor) -----------
      if (segments[0] === "fonts" && segments.length === 2 && (method === "GET" || method === "HEAD")) {
        return getFont(env, segments[1], method);
      }

      // ---- A partir de aquí todo exige el token compartido -------------
      if (!authorized(request, env)) return text("Unauthorized", 401);

      // ---- /library ----------------------------------------------------
      if (segments.length === 1 && segments[0] === "library") {
        if (method === "GET") return getLibrary(env);
        if (method === "PUT") return putLibrary(request, env);
      }

      // ---- /usage ------------------------------------------------------
      if (segments.length === 1 && segments[0] === "usage" && method === "GET") {
        return getUsage(env);
      }

      // ---- /media , /media/:name ---------------------------------------
      if (segments[0] === "media") {
        if (segments.length === 1 && method === "GET") return listMedia(env);
        if (segments.length === 2) {
          const name = safeMediaName(segments[1]);
          if (!name) return text("Bad media name", 400);
          if (method === "HEAD") return headMedia(env, name);
          if (method === "GET") return getMedia(env, name);
          if (method === "PUT") return putMedia(request, env, name);
          if (method === "DELETE") return deleteMedia(env, name);
        }
      }

      // ---- /share , /share/:boardId ------------------------------------
      if (segments[0] === "share") {
        if (segments.length === 1 && method === "POST") return createShare(request, env);
        if (segments.length === 2) {
          if (method === "GET") return getShare(env, segments[1]);
          if (method === "DELETE") return deleteShare(env, segments[1]);
        }
      }

      return text("Not found", 404);
    } catch (err) {
      return text(`Error: ${(err as Error).message}`, 500);
    }
  },
} satisfies ExportedHandler<Env>;

// ---------------------------------------------------------------------------
// library
// ---------------------------------------------------------------------------

async function getLibrary(env: Env): Promise<Response> {
  const row = await env.DB.prepare("SELECT revision, json FROM library WHERE id = ?")
    .bind(LIBRARY_ID)
    .first<{ revision: number; json: string }>();
  if (!row) return text("No library yet", 404);
  return json({ revision: row.revision, json: row.json });
}

async function putLibrary(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as { baseRevision?: number; json?: string };
  if (typeof body.json !== "string") return text("Missing json", 400);

  const current = await env.DB.prepare("SELECT revision FROM library WHERE id = ?")
    .bind(LIBRARY_ID)
    .first<{ revision: number }>();
  const currentRevision = current?.revision ?? 0;

  // Control optimista: el cliente debe basarse en la revisión que conoce.
  if ((body.baseRevision ?? 0) !== currentRevision) {
    const latest = await getLibrary(env);
    return new Response(await latest.text(), { status: 409, headers: latest.headers });
  }

  const nextRevision = currentRevision + 1;
  const now = new Date().toISOString();

  await env.DB.prepare(
    "INSERT INTO library (id, revision, json, updated_at) VALUES (?1, ?2, ?3, ?4) " +
      "ON CONFLICT(id) DO UPDATE SET revision = ?2, json = ?3, updated_at = ?4",
  )
    .bind(LIBRARY_ID, nextRevision, body.json, now)
    .run();

  return json({ revision: nextRevision });
}

// ---------------------------------------------------------------------------
// media (R2)
// ---------------------------------------------------------------------------

async function headMedia(env: Env, name: string): Promise<Response> {
  const obj = await env.MEDIA.head(name);
  return new Response(null, { status: obj ? 200 : 404 });
}

async function getMedia(env: Env, name: string): Promise<Response> {
  const obj = await env.MEDIA.get(name);
  if (!obj) return text("Not found", 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  return new Response(obj.body, { headers });
}

async function putMedia(request: Request, env: Env, name: string): Promise<Response> {
  if (!request.body) return text("Empty body", 400);
  await env.MEDIA.put(name, request.body, {
    httpMetadata: { contentType: request.headers.get("content-type") ?? "application/octet-stream" },
  });
  return json({ ok: true });
}

async function deleteMedia(env: Env, name: string): Promise<Response> {
  await env.MEDIA.delete(name);   // idempotente: borrar algo inexistente no es error
  return json({ ok: true });
}

async function listMedia(env: Env): Promise<Response> {
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.MEDIA.list({ cursor, limit: 1000 });
    for (const obj of page.objects) keys.push(obj.key);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return json({ keys });
}

/** Almacenamiento usado en R2: número de objetos y bytes totales (suma recorriendo R2). */
async function getUsage(env: Env): Promise<Response> {
  let count = 0;
  let bytes = 0;
  let cursor: string | undefined;
  do {
    const page = await env.MEDIA.list({ cursor, limit: 1000 });
    for (const obj of page.objects) {
      count++;
      bytes += obj.size;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return json({ count, bytes });
}

// ---------------------------------------------------------------------------
// compartir (autenticado)
// ---------------------------------------------------------------------------

/** Da (o reutiliza) un token público para un tablero. Idempotente: un tablero, un token. */
async function createShare(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as { boardId?: string };
  const boardId = body.boardId;
  if (typeof boardId !== "string" || !boardId) return text("Missing boardId", 400);

  const existing = await env.DB.prepare("SELECT token FROM shared WHERE board_id = ?")
    .bind(boardId)
    .first<{ token: string }>();
  if (existing) return json({ token: existing.token });

  const token = crypto.randomUUID().replace(/-/g, "");
  await env.DB.prepare("INSERT INTO shared (token, board_id, created_at) VALUES (?1, ?2, ?3)")
    .bind(token, boardId, new Date().toISOString())
    .run();
  return json({ token });
}

async function getShare(env: Env, boardId: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT token FROM shared WHERE board_id = ?")
    .bind(boardId)
    .first<{ token: string }>();
  return row ? json({ token: row.token }) : text("Not shared", 404);
}

async function deleteShare(env: Env, boardId: string): Promise<Response> {
  await env.DB.prepare("DELETE FROM shared WHERE board_id = ?").bind(boardId).run();
  return json({ ok: true });
}

// ---------------------------------------------------------------------------
// visor público (sin token)
// ---------------------------------------------------------------------------

type SharedItem = Record<string, unknown> & { kind?: string; media?: string };
type SharedBoard = { name?: string; items?: SharedItem[] };

/** Resuelve el token -> tablero vivo leído de la fila `library`. null si no existe. */
async function resolveSharedBoard(env: Env, token: string): Promise<SharedBoard | null> {
  const share = await env.DB.prepare("SELECT board_id FROM shared WHERE token = ?")
    .bind(token)
    .first<{ board_id: string }>();
  if (!share) return null;
  const row = await env.DB.prepare("SELECT json FROM library WHERE id = ?")
    .bind(LIBRARY_ID)
    .first<{ json: string }>();
  if (!row) return null;
  const library = JSON.parse(row.json) as { boards?: SharedBoard[] & { id?: string }[] };
  const board = (library.boards ?? []).find((b) => (b as { id?: string }).id === share.board_id);
  return board ?? null;
}

/** Solo las piezas que el visor sabe dibujar (se omiten las carpetas `board`). */
const VIEWABLE_KINDS = new Set(["image", "note", "text", "frame"]);

async function getSharedData(env: Env, token: string): Promise<Response> {
  const board = await resolveSharedBoard(env, token);
  if (!board) return text("Not found", 404);
  const items = (board.items ?? []).filter((i) => VIEWABLE_KINDS.has(String(i.kind)));
  return json({ name: board.name ?? "Moodboard", items });
}

/** Tipo MIME de imagen según la extensión del archivo (los nombres son UUID.ext). */
function imageMime(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  const table: Record<string, string> = {
    jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif",
    webp: "image/webp", heic: "image/heic", heif: "image/heif",
    tif: "image/tiff", tiff: "image/tiff", bmp: "image/bmp", svg: "image/svg+xml",
  };
  return table[ext] ?? "application/octet-stream";
}

async function getSharedMedia(env: Env, token: string, rawName: string, method: string): Promise<Response> {
  const name = safeMediaName(rawName);
  if (!name) return text("Bad media name", 400);
  const board = await resolveSharedBoard(env, token);
  if (!board) return text("Not found", 404);
  // Solo imágenes que el propio tablero usa: así el link no deja enumerar R2.
  const referenced = new Set((board.items ?? []).map((i) => i.media).filter(Boolean));
  if (!referenced.has(name)) return text("Not found", 404);

  const obj = await env.MEDIA.get(name);
  if (!obj) return text("Not found", 404);
  // Importante: forzamos un Content-Type de imagen. En R2 las fotos están guardadas como
  // application/octet-stream, y los crawlers (Instagram, WhatsApp) descartan la miniatura si
  // el tipo no es image/*. Los navegadores lo adivinan, pero las redes sociales no.
  const headers = new Headers();
  headers.set("content-type", imageMime(name));
  headers.set("etag", obj.httpEtag);
  headers.set("cache-control", "public, max-age=3600");
  return new Response(method === "HEAD" ? null : obj.body, { headers });
}

/** Imagen de portada para la vista previa del enlace: la elegida por el usuario o la primera foto.
 *  Si no hay portada elegida, prefiere un formato que las redes previsualizan bien (jpg/png/gif). */
function coverMedia(board: SharedBoard): string | null {
  const items = board.items ?? [];
  const chosen = (board as { cover?: string }).cover;
  if (chosen && items.some((i) => i.media === chosen)) return chosen;
  const medias = items.map((i) => i.media).filter(Boolean) as string[];
  const safe = /\.(jpe?g|png|gif)$/i;
  return medias.find((m) => safe.test(m)) ?? medias[0] ?? null;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}

/** Fuentes que se ven igual en la web: nombre de familia (como en macOS) -> spec de Google Fonts.
 *  Para que una fuente del tablero se vea en el navegador, debe estar en esta lista (y el usuario
 *  debe tenerla instalada en su Mac para usarla en la app). El visor solo carga las que se usan. */
const WEB_FONTS: Record<string, string> = {
  "Inter": "Inter:wght@400;600;700",
  "Poppins": "Poppins:wght@400;600;700",
  "Montserrat": "Montserrat:wght@400;600;700",
  "Playfair Display": "Playfair+Display:wght@400;600;700",
  "Lora": "Lora:wght@400;600;700",
  "Roboto Mono": "Roboto+Mono:wght@400;600;700",
  "Caveat": "Caveat:wght@400;700",
  "Bebas Neue": "Bebas+Neue",
};

/** Fuentes de autor autoservidas desde R2 (clave `fonts/<archivo>`): nombre de familia (como en
 *  macOS) -> archivo. Deben coincidir con `WebFonts.customFamilies` de la app. */
const CUSTOM_FONTS: Record<string, string> = {
  "Anaktoria": "Anaktoria.ttf",
  "ASTREVA": "Astreva.ttf",
};

/** <link> de Google Fonts + <style> con @font-face de las fuentes de autor que usa el tablero. */
function fontLinks(board: SharedBoard | null): string {
  const used = new Set((board?.items ?? []).map((i) => (i as { fontFamily?: string }).fontFamily).filter(Boolean));

  let out = "";
  const specs = Object.keys(WEB_FONTS).filter((f) => used.has(f)).map((f) => WEB_FONTS[f]);
  if (specs.length > 0) {
    const href = "https://fonts.googleapis.com/css2?" + specs.map((s) => "family=" + s).join("&") + "&display=swap";
    out +=
      '<link rel="preconnect" href="https://fonts.googleapis.com">' +
      '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>' +
      '<link rel="stylesheet" href="' + href + '">';
  }

  const faces = Object.keys(CUSTOM_FONTS)
    .filter((f) => used.has(f))
    .map((f) => '@font-face{font-family:"' + f + '";src:url("/fonts/' + CUSTOM_FONTS[f] +
      '") format("truetype");font-display:swap;}');
  if (faces.length > 0) out += "<style>" + faces.join("") + "</style>";

  return out;
}

/** Tipo MIME de una fuente según su extensión. */
function fontMime(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  const table: Record<string, string> = {
    ttf: "font/ttf", otf: "font/otf", woff: "font/woff", woff2: "font/woff2",
  };
  return table[ext] ?? "application/octet-stream";
}

/** Sirve una fuente de autor desde R2 (clave `fonts/<name>`). Pública, cacheable. */
async function getFont(env: Env, rawName: string, method: string): Promise<Response> {
  const name = safeMediaName(rawName);
  if (!name) return text("Bad name", 400);
  const obj = await env.MEDIA.get("fonts/" + name);
  if (!obj) return text("Not found", 404);
  const headers = new Headers();
  headers.set("content-type", fontMime(name));
  headers.set("etag", obj.httpEtag);
  headers.set("cache-control", "public, max-age=604800");
  headers.set("access-control-allow-origin", "*");
  return new Response(method === "HEAD" ? null : obj.body, { headers });
}

/** Sirve la página del visor con metadatos Open Graph por tablero (vista previa en redes). */
async function serveViewer(origin: string, env: Env, token: string): Promise<Response> {
  const board = await resolveSharedBoard(env, token);
  const title = escapeHtml(board?.name || "Moodboard");
  const pageURL = origin + "/s/" + token;
  const cover = board ? coverMedia(board) : null;
  const image = cover ? origin + "/s/" + token + "/media/" + encodeURIComponent(cover) : "";

  const meta =
    `<title>${title}</title>\n` +
    `<meta property="og:type" content="website">\n` +
    `<meta property="og:title" content="${title}">\n` +
    `<meta property="og:description" content="Mira este tablero en Moodboard">\n` +
    `<meta property="og:url" content="${pageURL}">\n` +
    (image ? `<meta property="og:image" content="${image}">\n` : "") +
    `<meta name="twitter:card" content="summary_large_image">\n` +
    `<meta name="twitter:title" content="${title}">\n` +
    (image ? `<meta name="twitter:image" content="${image}">\n` : "");

  return new Response(VIEWER_HTML.replace("__META__", meta).replace("__FONTS__", fontLinks(board)), {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

// ---------------------------------------------------------------------------
// página del visor (HTML autocontenido; sin dependencias externas)
// ---------------------------------------------------------------------------

const VIEWER_HTML = `<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
__META__
__FONTS__
<style>
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  #viewport { position: fixed; inset: 0; background-color: #ececee;
    background-image: radial-gradient(circle, rgba(0,0,0,0.13) 1.3px, transparent 1.4px);
    background-size: 24px 24px; cursor: grab; touch-action: none; }
  #viewport.grabbing { cursor: grabbing; }
  /* El tablero es plano: las piezas no reciben eventos, así cualquier arrastre desplaza el
     lienzo y nunca se selecciona ni se arrastra una imagen suelta. */
  #surface { position: absolute; top: 0; left: 0; transform-origin: 0 0; pointer-events: none; }
  .item { position: absolute; overflow: hidden; pointer-events: none; }
  .item img { display: block; position: absolute; top: 0; left: 0;
    -webkit-user-drag: none; user-drag: none; }
  .note { border-radius: 8px; padding: 12px; color: rgba(0,0,0,0.85);
    white-space: pre-wrap; word-break: break-word; box-shadow: 0 4px 8px rgba(0,0,0,0.3); }
  .text { padding: 4px 5px; white-space: pre-wrap; word-break: break-word; }
  .frame { border-radius: 8px; padding: 5px; box-shadow: 0 4px 10px rgba(0,0,0,0.35);
    display: flex; flex-direction: column; }
  .frame .pic { position: relative; flex: 1; border-radius: 5px; overflow: hidden; }
  .frame .cap { height: 34px; padding: 0 6px; display: flex; align-items: center;
    font-size: 12px; color: #111; overflow: hidden; }
  #title { position: fixed; top: 14px; left: 16px; padding: 6px 12px; border-radius: 999px;
    background: rgba(255,255,255,0.85); backdrop-filter: blur(8px); font-size: 13px;
    font-weight: 600; color: #222; box-shadow: 0 2px 6px rgba(0,0,0,0.12); max-width: 60vw;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  #msg { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;
    color: #777; font-size: 15px; }
  #zoom { position: fixed; right: 14px; bottom: 14px; display: flex; gap: 6px; user-select: none; }
  #zoom button { border: none; background: rgba(255,255,255,0.9); backdrop-filter: blur(8px);
    box-shadow: 0 2px 6px rgba(0,0,0,0.15); border-radius: 10px; min-width: 42px; height: 42px;
    font-size: 18px; color: #222; cursor: pointer; padding: 0 12px; line-height: 1; }
  #zoom button:active { background: #dcdcdc; }
</style>
</head>
<body>
<div id="viewport"><div id="surface"></div></div>
<div id="title"></div>
<div id="msg">Cargando…</div>
<div id="zoom">
  <button id="zout" aria-label="Alejar">&#8722;</button>
  <button id="zfit">Ajustar</button>
  <button id="zin" aria-label="Acercar">+</button>
</div>
<script>
(function () {
  var PATH = location.pathname.split('/').filter(Boolean);
  var TOKEN = PATH[1];
  var MEDIA = '/s/' + TOKEN + '/media/';
  var DATA = '/s/' + TOKEN + '/data';
  var SYS = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

  var viewport = document.getElementById('viewport');
  var surface = document.getElementById('surface');
  var titleEl = document.getElementById('title');
  var msgEl = document.getElementById('msg');

  // Tablero plano: sin menú contextual (guardar/copiar) ni arrastre nativo de imágenes.
  document.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  document.addEventListener('dragstart', function (e) { e.preventDefault(); });

  function fontFamily(it) { return it.fontFamily ? '"' + it.fontFamily + '", ' + SYS : SYS; }
  function hex(h, fb) { return '#' + (h || fb); }

  function normCrop(c) {
    if (!c) return null;
    if (Array.isArray(c)) {
      if (c.length === 4 && typeof c[0] === 'number') return { x: c[0], y: c[1], w: c[2], h: c[3] };
      if (c.length === 2 && Array.isArray(c[0])) return { x: c[0][0], y: c[0][1], w: c[1][0], h: c[1][1] };
    }
    if (typeof c === 'object') {
      if (c.origin && c.size) return { x: c.origin.x, y: c.origin.y, w: c.size.width, h: c.size.height };
      if ('x' in c && 'width' in c) return { x: c.x, y: c.y, w: c.width, h: c.height };
    }
    return null;
  }

  // Replica CroppedImage: cubre el marco mostrando solo la zona recortada.
  function placeImage(img, boxW, boxH, crop) {
    var natW = img.naturalWidth || boxW, natH = img.naturalHeight || boxH;
    if (!crop) {
      var s0 = Math.max(boxW / natW, boxH / natH);
      var dw0 = natW * s0, dh0 = natH * s0;
      img.style.width = dw0 + 'px'; img.style.height = dh0 + 'px';
      img.style.transform = 'translate(' + (-(dw0 - boxW) / 2) + 'px,' + (-(dh0 - boxH) / 2) + 'px)';
      return;
    }
    var cw = Math.max(crop.w * natW, 1), ch = Math.max(crop.h * natH, 1);
    var s = Math.max(boxW / cw, boxH / ch);
    var dw = natW * s, dh = natH * s;
    var ox = -crop.x * natW * s - (cw * s - boxW) / 2;
    var oy = -crop.y * natH * s - (ch * s - boxH) / 2;
    img.style.width = dw + 'px'; img.style.height = dh + 'px';
    img.style.transform = 'translate(' + ox + 'px,' + oy + 'px)';
  }

  function imageEl(it, boxW, boxH) {
    var img = document.createElement('img');
    var crop = normCrop(it.crop);
    img.src = MEDIA + it.media;
    img.onload = function () { placeImage(img, boxW, boxH, crop); };
    return img;
  }

  function render(items) {
    items.sort(function (a, b) { return (a.z || 0) - (b.z || 0); });
    items.forEach(function (it) {
      var el = document.createElement('div');
      el.className = 'item';
      el.style.left = it.x + 'px';
      el.style.top = it.y + 'px';
      el.style.width = it.w + 'px';
      el.style.height = it.h + 'px';
      el.style.zIndex = String(it.z || 0);

      if (it.kind === 'image') {
        if (it.media) el.appendChild(imageEl(it, it.w, it.h));
      } else if (it.kind === 'note') {
        el.classList.add('note');
        el.style.background = hex(it.colorHex, 'FFE9A8');
        el.style.fontFamily = fontFamily(it);
        el.style.fontSize = (it.fontSize || 14) + 'px';
        el.textContent = it.text || '';
      } else if (it.kind === 'text') {
        el.classList.add('text');
        el.style.color = it.textColorHex ? hex(it.textColorHex) : '#1C1C1E';
        el.style.fontFamily = fontFamily(it);
        el.style.fontSize = (it.fontSize || 12) + 'px';
        el.textContent = it.text || '';
      } else if (it.kind === 'frame') {
        el.classList.add('frame');
        el.style.background = hex(it.colorHex, 'FFE9A8');
        var pic = document.createElement('div');
        pic.className = 'pic';
        if (it.media) pic.appendChild(imageEl(it, it.w - 10, it.h - 44));
        var cap = document.createElement('div');
        cap.className = 'cap';
        cap.textContent = it.text || '';
        el.appendChild(pic);
        el.appendChild(cap);
      }
      surface.appendChild(el);
    });
  }

  var tx = 0, ty = 0, scale = 1;
  function apply() {
    surface.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
    viewport.style.backgroundPosition = tx + 'px ' + ty + 'px';
    viewport.style.backgroundSize = (24 * scale) + 'px ' + (24 * scale) + 'px';
  }

  function fit(items) {
    if (!items.length) { apply(); return; }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    items.forEach(function (it) {
      minX = Math.min(minX, it.x); minY = Math.min(minY, it.y);
      maxX = Math.max(maxX, it.x + it.w); maxY = Math.max(maxY, it.y + it.h);
    });
    var vw = viewport.clientWidth, vh = viewport.clientHeight, pad = 60;
    var bw = Math.max(maxX - minX, 1), bh = Math.max(maxY - minY, 1);
    scale = Math.min((vw - pad * 2) / bw, (vh - pad * 2) / bh, 1);
    tx = (vw - bw * scale) / 2 - minX * scale;
    ty = (vh - bh * scale) / 2 - minY * scale;
    apply();
  }

  // Zoom manteniendo fijo el punto (cx, cy) de la pantalla.
  function zoomAround(cx, cy, factor) {
    var next = Math.min(4, Math.max(0.1, scale * factor));
    var wx = (cx - tx) / scale, wy = (cy - ty) / scale;
    tx = cx - wx * next; ty = cy - wy * next; scale = next; apply();
  }

  // Un solo dedo/ratón desplaza; dos dedos hacen pellizco (zoom) y arrastran a la vez.
  var pointers = new Map();
  var pinchDist = 0, pinchMid = null;
  function twoPointers() {
    var p = Array.from(pointers.values());
    var dx = p[0].x - p[1].x, dy = p[0].y - p[1].y;
    return { dist: Math.hypot(dx, dy), mid: { x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 } };
  }
  viewport.addEventListener('pointerdown', function (e) {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    viewport.setPointerCapture(e.pointerId);
    viewport.classList.add('grabbing');
    if (pointers.size === 2) { var d = twoPointers(); pinchDist = d.dist; pinchMid = d.mid; }
  });
  viewport.addEventListener('pointermove', function (e) {
    if (!pointers.has(e.pointerId)) return;
    var prev = pointers.get(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) {
      tx += e.clientX - prev.x; ty += e.clientY - prev.y; apply();
    } else if (pointers.size === 2) {
      var d = twoPointers();
      if (pinchDist > 0) zoomAround(d.mid.x, d.mid.y, d.dist / pinchDist);
      if (pinchMid) { tx += d.mid.x - pinchMid.x; ty += d.mid.y - pinchMid.y; apply(); }
      pinchDist = d.dist; pinchMid = d.mid;
    }
  });
  function dropPointer(e) {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) { pinchDist = 0; pinchMid = null; }
    if (pointers.size === 0) viewport.classList.remove('grabbing');
  }
  viewport.addEventListener('pointerup', dropPointer);
  viewport.addEventListener('pointercancel', dropPointer);

  // Rueda del ratón o pellizco del trackpad (llega como wheel + ctrl).
  viewport.addEventListener('wheel', function (e) {
    e.preventDefault();
    var factor = e.ctrlKey ? (1 - e.deltaY * 0.01) : (1 - e.deltaY * 0.0015);
    zoomAround(e.clientX, e.clientY, factor);
  }, { passive: false });

  // Botones de zoom (hacen zoom hacia el centro de la pantalla).
  var ITEMS = [];
  function centerZoom(factor) { zoomAround(viewport.clientWidth / 2, viewport.clientHeight / 2, factor); }
  document.getElementById('zin').onclick = function () { centerZoom(1.25); };
  document.getElementById('zout').onclick = function () { centerZoom(0.8); };
  document.getElementById('zfit').onclick = function () { fit(ITEMS); };

  fetch(DATA)
    .then(function (r) { if (!r.ok) throw new Error('404'); return r.json(); })
    .then(function (data) {
      msgEl.remove();
      document.title = data.name || 'Moodboard';
      titleEl.textContent = data.name || 'Moodboard';
      ITEMS = data.items || [];
      render(ITEMS);
      fit(ITEMS);
    })
    .catch(function () { msgEl.textContent = 'Este tablero ya no está disponible.'; });
})();
</script>
</body>
</html>`;

// Service worker de la extensión: hace todas las llamadas de red (correr aquí, con host_permissions,
// evita el CORS que bloquearía estas peticiones desde el content script). Sube los bytes de la imagen
// a R2 (PUT /media/:name) y encola la captura en la bandeja (POST /inbox).

/** Config guardada por el popup: { serverUrl, token, email }. */
async function getConfig() {
  const { serverUrl, token } = await chrome.storage.local.get(["serverUrl", "token"]);
  return { serverUrl, token };
}

/** Extensión de archivo a partir del tipo MIME de la imagen (para el nombre UUID.ext). */
function extForMime(mime) {
  const table = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/heic": "heic",
    "image/bmp": "bmp",
  };
  return table[mime] || "jpg";
}

/** Descarga la imagen, la sube al servidor y la añade a la bandeja. Devuelve {ok} o {ok:false,error}. */
async function capture(imageUrl, sourceUrl) {
  const { serverUrl, token } = await getConfig();
  if (!serverUrl || !token) {
    return { ok: false, error: "Inicia sesión en la extensión de Moodboard." };
  }
  const base = serverUrl.replace(/\/$/, "");

  // 1) Bytes de la imagen (desde el CDN).
  let blob;
  try {
    const res = await fetch(imageUrl);
    if (!res.ok) throw new Error("HTTP " + res.status);
    blob = await res.blob();
  } catch (e) {
    return { ok: false, error: "No se pudo descargar la imagen." };
  }

  const mime = blob.type || "image/jpeg";
  const ext = extForMime(mime);
  const name = crypto.randomUUID().replace(/-/g, "") + "." + ext;

  // Dimensiones (opcionales; ayudan a la app a dibujarla a su proporción).
  let w, h;
  try {
    const bmp = await createImageBitmap(blob);
    w = bmp.width;
    h = bmp.height;
    bmp.close();
  } catch (_) {
    /* sin dimensiones: la app las lee del archivo igualmente */
  }

  // 2) Subir los bytes a R2.
  try {
    const put = await fetch(base + "/media/" + name, {
      method: "PUT",
      headers: { Authorization: "Bearer " + token, "Content-Type": mime },
      body: blob,
    });
    if (!put.ok) throw new Error("HTTP " + put.status);
  } catch (e) {
    return { ok: false, error: "No se pudo subir la imagen al servidor." };
  }

  // 3) Encolar en la bandeja de entrada.
  try {
    const post = await fetch(base + "/inbox", {
      method: "POST",
      headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify({ media: name, sourceUrl, kind: "image", w, h }),
    });
    if (!post.ok) throw new Error("HTTP " + post.status);
  } catch (e) {
    return { ok: false, error: "No se pudo guardar en la bandeja." };
  }

  return { ok: true };
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "capture") {
    capture(msg.imageUrl, msg.sourceUrl).then(sendResponse);
    return true; // respuesta asíncrona
  }
});

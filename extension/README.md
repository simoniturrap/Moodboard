# Extensión de Chrome — Capturar a Moodboard

Guarda imágenes de la web (de momento, Instagram) en la **bandeja de entrada** de Moodboard con
un clic. Desde la app, cada captura se puede cargar al tablero que quieras.

## Cómo funciona

1. **content.js** inyecta un botón flotante sobre la imagen que esté bajo el cursor en Instagram.
2. Al pulsarlo, **background.js** (service worker) descarga los bytes de la imagen, los sube a R2
   (`PUT /media/:name`) y encola la captura en el servidor (`POST /inbox`). Correr la red en el
   service worker, con `host_permissions`, evita el CORS que bloquearía estas peticiones.
3. La app de Moodboard baja la bandeja (`GET /inbox`) y la muestra junto a la papelera. Al cargar
   una captura en un tablero, se convierte en una pieza normal y se consume del servidor.

## Instalar (modo desarrollador)

1. Despliega el servidor con el nuevo endpoint de bandeja (ver abajo).
2. Abre `chrome://extensions`, activa **Modo de desarrollador**.
3. **Cargar descomprimida** → selecciona esta carpeta `extension/`.
4. Abre el popup de la extensión e inicia sesión con la **misma URL de servidor, email y
   contraseña** que usas en la app de Moodboard.
5. Entra en Instagram, pasa el cursor sobre una foto y pulsa el botón de la bandeja.

## Desplegar los cambios del servidor

El endpoint `/inbox` necesita una tabla nueva en D1. Desde `server/`:

```sh
npm run schema     # crea la tabla inbox (CREATE TABLE IF NOT EXISTS, idempotente)
npm run deploy     # publica el Worker con las rutas /inbox
```

## Notas

- `host_permissions` es `<all_urls>` porque el service worker necesita descargar imágenes de
  CDNs arbitrarios y subirlas a tu servidor (cuya URL eliges tú). El *content script*, en cambio,
  sólo corre en Instagram (`content_scripts.matches`).
- Para capturar en otros sitios además de Instagram, añade sus dominios a `content_scripts.matches`
  en `manifest.json`.
- El token de sync se guarda en `chrome.storage.local`. Cerrar sesión lo borra.

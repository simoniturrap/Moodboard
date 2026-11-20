-- Esquema D1 para Moodboard.
-- Aplicar con:  npx wrangler d1 execute moodboard --remote --file=./schema.sql

-- Documento único (la biblioteca completa en JSON). Siempre id = 'default'.
CREATE TABLE IF NOT EXISTS library (
  id         TEXT PRIMARY KEY,
  revision   INTEGER NOT NULL,
  json       TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Tableros compartidos con un link público. Cada tablero tiene como mucho un token
-- (board_id es único). El visor web lee el tablero en vivo desde la fila `library`.
CREATE TABLE IF NOT EXISTS shared (
  token      TEXT PRIMARY KEY,
  board_id   TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

-- Credenciales de la única cuenta (id siempre = 1). La contraseña se guarda derivada
-- con PBKDF2-SHA256 (nunca en claro). Al iniciar sesión, el Worker valida y entrega el
-- token de sync, que es lo que la app usa luego para todas las peticiones.
CREATE TABLE IF NOT EXISTS auth (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  email      TEXT NOT NULL,
  pw_hash    TEXT NOT NULL,
  pw_salt    TEXT NOT NULL,
  iterations INTEGER NOT NULL
);

-- Bandeja de entrada: imágenes capturadas desde fuera de la app (p. ej. la extensión de
-- Chrome en Instagram). Cola simple, sin control de revisión: la extensión sólo añade y
-- la app consume. Al cargar una pieza en un tablero, la app la convierte en parte de la
-- biblioteca y borra esta fila; el archivo ya está subido a R2 con su nombre `media`.
CREATE TABLE IF NOT EXISTS inbox (
  id         TEXT PRIMARY KEY,
  media      TEXT NOT NULL,
  source_url TEXT,
  kind       TEXT NOT NULL DEFAULT 'image',
  w          INTEGER,
  h          INTEGER,
  created_at TEXT NOT NULL
);

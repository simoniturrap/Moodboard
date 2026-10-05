# Moodboard

App nativa de macOS (SwiftUI) para armar moodboards de fotografía, storyboards y guiones de cine.

## Correr

```bash
swift run              # desarrollo, rápido
./build.sh             # arma dist/Moodboard.app
open dist/Moodboard.app
```

También podés abrir `Package.swift` con Xcode y darle ▶.

## Cómo se usa

| Acción | Cómo |
|---|---|
| Tableros | Botón flotante arriba a la izquierda: **+** crea uno (o ⌘N, pide el nombre); la flecha despliega los recientes y un buscador |
| Pestañas | La **casa** del principio vuelve al inicio sin cerrar ninguna pestaña (⇧⌘H). El **+** tras la última pestaña abre la modal de creación. ⌘W cierra el tablero activo, ⌘1…⌘8 van a esa pestaña y ⌘9 a la última, ⇧⌘] / ⇧⌘[ siguiente / anterior. Los tableros abiertos aparecen como pestañas en la barra de la ventana, junto a los iconos: se reparten el ancho, los nombres largos terminan en «…» (el nombre completo sale al pasar el ratón) y si no caben se desplazan de lado. Doble clic renombra, × cierra (cualquiera, también la última), clic derecho para duplicar o eliminar |
| Inicio | Sin pestañas abiertas se muestra el inicio: tarjeta **Crea un nuevo tablero** y los tableros recientes con su miniatura y un buscador. Clic abre, clic derecho duplica o elimina |
| Agregar fotos | Arrastralas desde el Finder al lienzo, o botón **Imagen**. Entran con 240 pt de ancho |
| Cortar / Copiar / Pegar | ⌘X / ⌘C / ⌘V con cualquier pieza, también entre tableros. Pegar deja la copia 20 px corrida (o centrada si el original no está a la vista); tras cortar, pega en el mismo sitio. Lo copiado también se puede pegar en otras apps (imagen y texto). Desde otras apps: imágenes, archivos o texto → nota |
| Seleccionar todo | ⌘A |
| Menú de la foto | Clic derecho sobre una foto: Copiar, Cortar, Duplicar, Descargar… (guarda en Descargas; si está recortada, guarda el recorte a resolución completa) |
| Herramientas | Paleta flotante a la derecha. **T** activa Texto: clic en el fondo crea un bloque sin fondo con el cursor ya dentro, listo para escribir. **N** activa Nota (bloque con fondo de color). Esc suelta la herramienta. Doble clic en el fondo también crea una nota |
| Opciones del elemento | Al hacer clic en una pieza, la paleta de la derecha cambia (animada) a sus opciones. Texto y notas: **Tamaño** (Título 32 · Subtítulo 18 · Texto 12), **Fuente** y **Color**. Viñetas: Color. Todas: al frente, atrás, duplicar, eliminar |
| Fuentes | En **Fuente**: fuentes del sistema, ★ para favoritas (quedan arriba), clic derecho sobre una fuente para Título / Subtítulo / Texto |
| Color | Bloque de texto: color de la letra. Nota y viñeta: color del fondo. Muestras rápidas o **Personalizado** con el selector del sistema |
| Viñeta de storyboard | Botón **Viñeta** — imagen 16:9 con pie de texto editable |
| Editar texto | Doble clic sobre la nota, el texto o la viñeta |
| Ver y recortar foto | Doble clic sobre la foto: se abre a pantalla completa con la barra de recorte abajo (Libre, Original, 1:1, 4:5, 3:4, 3:2, 16:9). Arrastrar dentro mueve el marco; esquinas (y lados en Libre) lo redimensionan. ↩ aplica, Esc o clic fuera cancela, **Restablecer** vuelve a la foto entera. El original no se toca |
| Seleccionar | Clic sobre la pieza (mover no la selecciona); se marca con un contorno blanco interno de 2 px. ⇧ + clic suma o quita. Arrastrar sobre el fondo dibuja un marco de selección (⇧ suma) |
| Mover | Arrastrar, libre. Al soltar se imanta a una retícula invisible de 10 pt y, tipo masonry, deja 10 pt justos con la pieza vecina si queda cerca (⌘ lo desactiva). Si la pieza está seleccionada, se mueve todo el grupo. Con ⇧ el movimiento se limita al eje en el que más se mueve (sólo horizontal o sólo vertical) |
| Duplicar arrastrando | ⌥ + arrastrar: se lleva una copia y el original queda en su sitio |
| Redimensionar | Arrastrar cualquier esquina; no hay marcas visibles, el cursor cambia al pasar. Al soltar, ancho y alto caen en la retícula; las fotos mantienen proporción, ⇧ la libera |
| Desplazar el lienzo | Mantener **espacio** o **H** y arrastrar (incluso sobre las piezas), o scroll de dos dedos |
| Zoom | Pellizco, ⌘ + scroll o los botones de la barra. **Z** alterna entre 100 % y el último zoom. Los saltos se animan con un rebote suave |
| Encuadrar todo | Botón **Ajustar** |
| Al abrir un tablero | Al abrir la app, o un tablero que no tenía pestaña, la vista se recoloca: la esquina superior izquierda del contenido queda a 100 px del borde, con el zoom que permita ver casi todo (máx. 100 %). Cambiar entre pestañas abiertas conserva la vista |
| Deshacer / Rehacer | ⌘Z / ⇧⌘Z |
| Duplicar / Eliminar | ⌘D / ⌫. ⌫ borra la pieza seleccionada o, si el último clic fue en una pestaña, el tablero |
| Papelera | Botón flotante abajo a la izquierda: restaurar o borrar para siempre. Guarda los últimos 100 elementos durante 30 días |
| Exportar PDF | Botón **Exportar PDF** de la barra: una página encuadrada a todo el contenido, sobre blanco. El texto blanco se exporta en negro |

## Guiones de cine

Además de tableros se pueden crear **guiones** (⇧⌘N, la tarjeta **Crea un nuevo guion** del inicio, o eligiendo *Guion* en la modal de «Nuevo…»). Viven igual que los tableros: pestañas, recientes, buscador, papelera y ⌘Z.

El editor es una hoja con formato estándar (carta, Courier 12, márgenes de 1,5" y 1"). Cada línea es un elemento:

| Elemento | Formato |
|---|---|
| Escena | MAYÚSCULAS, dos líneas en blanco antes. Escribir «int.» o «ext.» (con punto) la convierte sola en escena y en mayúsculas |
| Acción | Ancho completo |
| Personaje | MAYÚSCULAS, centrado sobre la columna del diálogo |
| Acotación | Entre paréntesis, a 3,1" |
| Diálogo | Columna de 3,5" a 2,5" |
| Transición | MAYÚSCULAS, alineada a la derecha |

| Tecla | Qué hace |
|---|---|
| ↩ | Nuevo elemento con el tipo que suele seguir (Escena → Acción, Personaje → Diálogo, Diálogo → Personaje). En un Personaje vacío, pasa a Acción. Si escribes como Acción el nombre de un personaje que ya existe, al pulsar ↩ se reconoce como Personaje y la línea siguiente es su Diálogo (centrado) |
| ⇥ / ⇧⇥ | Cambia el tipo de la línea actual (también desde la paleta de la derecha) |
| ⌥↩ | Salto de línea dentro del mismo elemento |
| ⌫ al principio | Une con la línea anterior |
| ↑ / ↓ | Pasa a la línea anterior / siguiente |

**Personajes y lugares**: el panel de la izquierda los va registrando a medida que escribes (con cuántas veces aparecen); clic salta a la primera aparición.

**Zoom**: sólo desde la barra: − / + cambian de 10 en 10 % (entre 50 y 300 %) y el porcentaje abre un submenú con tamaños fijos (50, 75, 100, 125, 150 y 200 %).

**Páginas**: la hoja se ve partida en páginas reales, con su número arriba a la derecha como en el PDF. El menú **Página X de N** de la barra dice en cuál estás y salta a cualquiera.

**Exportar PDF** pagina el guion: portada con el título y páginas numeradas desde la 2.

## Dónde viven los datos

`~/Library/Application Support/Moodboard/`
- `library.json` — tableros y posiciones
- `Media/` — copia de cada imagen que agregás (el original no se toca ni se mueve)

El guardado es automático, con medio segundo de retraso para no escribir en cada pixel arrastrado.

// Content script en Instagram: muestra un botón flotante sobre la imagen que esté bajo el cursor.
// Al pulsarlo, resuelve la URL de mayor resolución y pide al service worker que la guarde en la
// bandeja de entrada de Moodboard.
//
// Instagram superpone capas transparentes (<div>/<a>) encima de cada <img> para capturar los clics,
// así que un `mouseover` nunca recibe la imagen directamente. Por eso buscamos la imagen bajo el
// cursor con `elementsFromPoint`, atravesando esas capas.

(function () {
  const MIN_SIZE = 150; // ignora iconos y avatares: sólo fotos de verdad

  let currentImg = null;
  let hideTimer = null;
  let rafPending = false;

  const btn = document.createElement("button");
  btn.className = "mb-capture-btn";
  btn.type = "button";
  btn.title = "Guardar en Moodboard";
  btn.setAttribute("aria-label", "Guardar en Moodboard");
  btn.innerHTML = icon("tray");
  document.body.appendChild(btn);

  function icon(state) {
    if (state === "busy") return "⏳";
    if (state === "ok") return "✓";
    if (state === "err") return "!";
    return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
      '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline>' +
      '<path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>' +
      "</svg>";
  }

  function bigEnough(img) {
    const r = img.getBoundingClientRect();
    return r.width >= MIN_SIZE && r.height >= MIN_SIZE;
  }

  /** La imagen (visible y grande) que hay bajo el punto, atravesando las capas de Instagram. */
  function imageAtPoint(x, y) {
    const stack = document.elementsFromPoint(x, y);
    for (const el of stack) {
      if (el === btn) continue;
      if (el instanceof HTMLImageElement && bigEnough(el)) return el;
    }
    return null;
  }

  /** Mejor URL disponible para una <img> (la que se muestra suele ser la de más resolución). */
  function bestSrc(img) {
    return img.currentSrc || img.src || "";
  }

  function positionOver(img) {
    const r = img.getBoundingClientRect();
    btn.style.top = window.scrollY + r.top + 8 + "px";
    btn.style.left = window.scrollX + r.right - 40 + "px";
  }

  function show(img) {
    if (img !== currentImg) {
      btn.classList.remove("mb-ok", "mb-err", "mb-busy");
      btn.innerHTML = icon("tray");
    }
    currentImg = img;
    positionOver(img);
    btn.classList.add("mb-visible");
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      btn.classList.remove("mb-visible");
      currentImg = null;
    }, 300);
  }

  document.addEventListener(
    "mousemove",
    (e) => {
      if (rafPending) return;
      rafPending = true;
      const x = e.clientX, y = e.clientY;
      requestAnimationFrame(() => {
        rafPending = false;
        const img = imageAtPoint(x, y);
        if (img) {
          clearTimeout(hideTimer);
          show(img);
        } else if (currentImg) {
          scheduleHide();
        }
      });
    },
    true
  );

  // Mantener el botón pegado a la imagen al desplazarse.
  window.addEventListener(
    "scroll",
    () => {
      if (currentImg && btn.classList.contains("mb-visible")) positionOver(currentImg);
    },
    true
  );

  btn.addEventListener("mouseenter", () => clearTimeout(hideTimer));
  btn.addEventListener("mouseleave", scheduleHide);

  btn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!currentImg) return;
    const imageUrl = bestSrc(currentImg);
    if (!imageUrl) return;
    btn.innerHTML = icon("busy");
    btn.classList.add("mb-busy");
    chrome.runtime.sendMessage(
      { type: "capture", imageUrl, sourceUrl: location.href },
      (resp) => {
        btn.classList.remove("mb-busy");
        if (resp && resp.ok) {
          btn.innerHTML = icon("ok");
          btn.classList.add("mb-ok");
        } else {
          btn.innerHTML = icon("err");
          btn.classList.add("mb-err");
          btn.title = (resp && resp.error) || "Error al guardar";
        }
        setTimeout(() => {
          btn.innerHTML = icon("tray");
          btn.classList.remove("mb-ok", "mb-err");
          btn.title = "Guardar en Moodboard";
        }, 1600);
      }
    );
  });
})();

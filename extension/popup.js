// Popup de la extensión: inicia sesión contra el Worker (POST /login) y guarda la URL y el token
// devuelto en chrome.storage.local, que es lo que usa el service worker para subir las capturas.

const $ = (id) => document.getElementById(id);

async function render() {
  const { serverUrl, email } = await chrome.storage.local.get(["serverUrl", "email", "token"]);
  const { token } = await chrome.storage.local.get("token");
  if (token) {
    $("loginView").classList.add("hidden");
    $("sessionView").classList.remove("hidden");
    $("whoEmail").textContent = email || "";
    $("whoServer").textContent = serverUrl || "";
  } else {
    $("sessionView").classList.add("hidden");
    $("loginView").classList.remove("hidden");
    if (serverUrl) $("serverUrl").value = serverUrl;
    if (email) $("email").value = email;
  }
}

function setMsg(text, kind) {
  const el = $("msg");
  el.textContent = text;
  el.className = kind || "";
}

async function login() {
  const serverUrl = $("serverUrl").value.trim().replace(/\/$/, "");
  const email = $("email").value.trim();
  const password = $("password").value;
  if (!serverUrl || !email || !password) {
    setMsg("Completa todos los campos.", "err");
    return;
  }
  setMsg("Entrando…");
  try {
    const res = await fetch(serverUrl + "/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    if (res.status === 401) {
      setMsg("Email o contraseña incorrectos.", "err");
      return;
    }
    if (!res.ok) {
      setMsg("El servidor respondió con un error (" + res.status + ").", "err");
      return;
    }
    const data = await res.json();
    if (!data.token) {
      setMsg("El servidor no devolvió un token.", "err");
      return;
    }
    await chrome.storage.local.set({ serverUrl, email, token: data.token });
    setMsg("¡Listo!", "ok");
    render();
  } catch (e) {
    setMsg("No se pudo conectar con el servidor.", "err");
  }
}

async function logout() {
  await chrome.storage.local.remove("token");
  render();
}

$("loginBtn").addEventListener("click", login);
$("logoutBtn").addEventListener("click", logout);
document.addEventListener("DOMContentLoaded", render);
render();

// pappagei Vorlesen -- Service Worker.
// Einziger Ort, der mit dem lokalen pappagei-Backend spricht (host_permissions
// erlauben den Zugriff ohne CORS); Content-Script und Popup melden sich hier.

const BASE = "http://127.0.0.1:8765";

async function post(path, body) {
  try {
    const res = await fetch(BASE + path, {
      method: "POST",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    return res.ok;
  } catch {
    return false;
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "pappagei-speak-selection",
    title: "Mit pappagei vorlesen",
    contexts: ["selection"],
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === "pappagei-speak-selection" && info.selectionText) {
    post("/speak", { text: info.selectionText });
  }
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    if (msg.type === "speak" && typeof msg.text === "string") {
      sendResponse({ ok: await post("/speak", { text: msg.text }) });
    } else if (msg.type === "stop") {
      sendResponse({ ok: await post("/speak/stop") });
    } else if (msg.type === "health") {
      try {
        const res = await fetch(BASE + "/health");
        sendResponse({ ok: res.ok, health: await res.json() });
      } catch {
        sendResponse({ ok: false });
      }
    } else {
      sendResponse({ ok: false });
    }
  })();
  return true; // sendResponse laeuft asynchron
});

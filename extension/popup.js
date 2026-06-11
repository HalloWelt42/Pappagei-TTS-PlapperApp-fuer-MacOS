// pappagei Vorlesen -- Popup: Verbindungs-Status, Stopp, Einstellungen.

const dot = document.getElementById("dot");
const statusText = document.getElementById("statusText");
const stopButton = document.getElementById("stop");
const hoverCheckbox = document.getElementById("hoverButtons");

function showStatus(cls, text) {
  dot.className = cls;
  statusText.textContent = text;
}

async function refresh() {
  let resp = null;
  try {
    resp = await chrome.runtime.sendMessage({ type: "health" });
  } catch {
    // Service Worker gerade nicht wach; naechster Tick versucht es erneut.
  }
  if (!resp || !resp.ok) {
    showStatus("err", "App nicht erreichbar - pappagei starten");
    stopButton.disabled = true;
    return;
  }
  stopButton.disabled = false;
  const h = resp.health || {};
  if (h.loading) {
    showStatus("warn", "Modell wird geladen ...");
  } else if (h.loaded) {
    showStatus("ok", "Bereit (Modell " + (h.model || "?") + ")");
  } else {
    showStatus("warn", "Modell noch nicht geladen");
  }
}

stopButton.addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "stop" }, () => refresh());
});

chrome.storage.local.get({ hoverButtons: true }, (v) => {
  hoverCheckbox.checked = v.hoverButtons;
});
hoverCheckbox.addEventListener("change", () => {
  chrome.storage.local.set({ hoverButtons: hoverCheckbox.checked });
});

refresh();
setInterval(refresh, 2000);

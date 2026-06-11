// pappagei Vorlesen -- Content-Script.
// Zeigt beim Ueberfahren von Textabschnitten einen Vorlese-Knopf (Klick liest
// den Abschnitt, Shift-Klick ab hier bis zum Ende des Containers) und einen
// Knopf an markiertem Text. Gesprochen wird in der pappagei-App; hier wird
// nur Text eingesammelt und an den Service Worker gereicht.
(() => {
  "use strict";

  const MIN_BLOCK_CHARS = 40;
  const MAX_TEXT_CHARS = 50000;
  const BLOCK_SELECTOR =
    "p, li, blockquote, h1, h2, h3, h4, h5, h6, dd, dt, figcaption, td, th, pre";

  let hoverButtonsEnabled = true;
  let currentBlock = null;
  let hideTimer = 0;

  chrome.storage.local.get({ hoverButtons: true }, (v) => {
    hoverButtonsEnabled = v.hoverButtons;
  });
  chrome.storage.onChanged.addListener((changes) => {
    if (changes.hoverButtons) {
      hoverButtonsEnabled = changes.hoverButtons.newValue;
      if (!hoverButtonsEnabled) hideBlockButton();
    }
  });

  // --- Overlay im Shadow DOM, damit Seiten-CSS nicht hineinwirkt ------------
  const host = document.createElement("div");
  host.setAttribute("data-pappagei-overlay", "");
  host.style.cssText =
    "all:initial; position:absolute; top:0; left:0; width:0; height:0; z-index:2147483647;";
  const root = host.attachShadow({ mode: "closed" });

  const style = document.createElement("style");
  style.textContent = [
    ".btn { position:absolute; display:none; align-items:center; justify-content:center;",
    "  width:26px; height:26px; border:none; border-radius:13px; padding:0;",
    "  background:#1f6feb; color:#fff; cursor:pointer;",
    "  box-shadow:0 1px 4px rgba(0,0,0,.35); }",
    ".btn:hover { background:#388bfd; }",
    ".btn.ok { background:#2da44e; }",
    ".btn.err { background:#cf222e; }",
    ".btn svg { width:14px; height:14px; display:block; }",
  ].join("\n");
  root.appendChild(style);

  const SPEAKER_SVG =
    '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M3 9v6h4l5 5V4L7 9H3z"/>' +
    '<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M16 8a4.5 4.5 0 0 1 0 8"/></svg>';
  const CHECK_SVG =
    '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/></svg>';
  const CROSS_SVG =
    '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M19 6.4 17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19 12 13.4 17.6 19 19 17.6 13.4 12z"/></svg>';

  function makeButton(title) {
    const b = document.createElement("button");
    b.className = "btn";
    b.type = "button";
    b.title = title;
    b.innerHTML = SPEAKER_SVG;
    // mousedown abfangen: der Klick darf weder Fokus noch Auswahl zerstoeren.
    b.addEventListener("mousedown", (e) => e.preventDefault());
    root.appendChild(b);
    return b;
  }

  const blockBtn = makeButton("Abschnitt vorlesen (Shift-Klick: ab hier bis zum Ende)");
  const selBtn = makeButton("Auswahl vorlesen");

  function ensureMounted() {
    if (!host.isConnected) document.documentElement.appendChild(host);
  }

  function flashFeedback(btn, ok) {
    btn.classList.add(ok ? "ok" : "err");
    btn.innerHTML = ok ? CHECK_SVG : CROSS_SVG;
    btn.title = ok ? btn.title : "pappagei nicht erreichbar - läuft die App?";
    setTimeout(() => {
      btn.classList.remove("ok", "err");
      btn.innerHTML = SPEAKER_SVG;
      btn.style.display = "none";
    }, 900);
  }

  function send(btn, text) {
    const clipped = text.trim().slice(0, MAX_TEXT_CHARS);
    if (!clipped) return;
    try {
      chrome.runtime.sendMessage({ type: "speak", text: clipped }, (resp) => {
        flashFeedback(btn, !chrome.runtime.lastError && !!resp?.ok);
      });
    } catch {
      flashFeedback(btn, false);
    }
  }

  // --- Knopf am Textabschnitt ------------------------------------------------
  function showBlockButton(block) {
    ensureMounted();
    currentBlock = block;
    const rect = block.getBoundingClientRect();
    const x = rect.left + window.scrollX;
    const y = rect.top + window.scrollY;
    // Links neben den Abschnitt; wenn dort kein Platz ist, in die linke
    // obere Ecke des Abschnitts.
    const left = x >= 34 ? x - 32 : x + 4;
    blockBtn.style.left = left + "px";
    blockBtn.style.top = Math.max(y, window.scrollY + 2) + "px";
    blockBtn.style.display = "flex";
  }

  function hideBlockButton() {
    blockBtn.style.display = "none";
    currentBlock = null;
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hideBlockButton, 350);
  }

  function blockTextFrom(block, fromHere) {
    if (!fromHere) return block.innerText || "";
    const parts = [block.innerText || ""];
    let el = block.nextElementSibling;
    let total = parts[0].length;
    while (el && total < MAX_TEXT_CHARS) {
      const t = el.innerText;
      if (t && t.trim()) {
        parts.push(t);
        total += t.length;
      }
      el = el.nextElementSibling;
    }
    return parts.join("\n");
  }

  document.addEventListener(
    "mouseover",
    (e) => {
      if (!hoverButtonsEnabled) return;
      const target = e.target;
      if (!(target instanceof Element)) return;
      if (target === host) return;
      const block = target.closest(BLOCK_SELECTOR);
      if (!block) return;
      const text = block.innerText;
      if (!text || text.trim().length < MIN_BLOCK_CHARS) return;
      clearTimeout(hideTimer);
      if (block !== currentBlock) showBlockButton(block);
    },
    { capture: true, passive: true }
  );

  document.addEventListener(
    "mouseout",
    (e) => {
      if (!currentBlock) return;
      const to = e.relatedTarget;
      if (to instanceof Element && (to === host || to.closest?.(BLOCK_SELECTOR) === currentBlock)) return;
      scheduleHide();
    },
    { capture: true, passive: true }
  );

  blockBtn.addEventListener("mouseenter", () => clearTimeout(hideTimer));
  blockBtn.addEventListener("mouseleave", scheduleHide);
  blockBtn.addEventListener("click", (e) => {
    if (!currentBlock) return;
    send(blockBtn, blockTextFrom(currentBlock, e.shiftKey));
  });

  // --- Knopf an der Auswahl ----------------------------------------------------
  function updateSelectionButton() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.toString().trim()) {
      selBtn.style.display = "none";
      return;
    }
    // In Eingabefeldern nicht dazwischenfunken.
    const anchor = sel.anchorNode instanceof Element ? sel.anchorNode : sel.anchorNode?.parentElement;
    if (anchor?.closest("input, textarea, [contenteditable]")) {
      selBtn.style.display = "none";
      return;
    }
    ensureMounted();
    const rect = sel.getRangeAt(sel.rangeCount - 1).getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) return;
    selBtn.style.left = rect.right + window.scrollX + 6 + "px";
    selBtn.style.top = rect.bottom + window.scrollY + 6 + "px";
    selBtn.style.display = "flex";
  }

  document.addEventListener("mouseup", () => setTimeout(updateSelectionButton, 0), {
    capture: true,
    passive: true,
  });
  document.addEventListener("keyup", (e) => {
    if (e.shiftKey || e.key === "Shift") setTimeout(updateSelectionButton, 0);
  });
  document.addEventListener("selectionchange", () => {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) selBtn.style.display = "none";
  });

  selBtn.addEventListener("click", () => {
    const sel = window.getSelection();
    const text = sel ? sel.toString() : "";
    if (text.trim()) send(selBtn, text);
  });

  ensureMounted();
})();

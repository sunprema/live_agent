(function () {
  "use strict";

  if (window.__liveAgent) return;

  const BASE = "/live_agent";

  const state = {
    visible: false,
    activeTab: "liveviews",
    liveViews: [],
    expandedPids: {},
    assignsCache: {},
    selectedElement: null,
    pinnedContext: null,
    pickerActive: false,
    _pickerTarget: null,
    _pollTimer: null,
  };

  window.__liveAgent = { state };

  // ─── Element Picker ────────────────────────────────────────────────────────

  function startPicker() {
    state.pickerActive = true;
    state._pickerTarget = null;
    document.body.style.cursor = "crosshair";
    document.addEventListener("mouseover", onHover, true);
    document.addEventListener("mouseout", onOut, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKey, true);
    renderPickBtn();
  }

  function stopPicker() {
    state.pickerActive = false;
    document.body.style.cursor = "";
    document.removeEventListener("mouseover", onHover, true);
    document.removeEventListener("mouseout", onOut, true);
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("keydown", onKey, true);
    clearHighlight();
    state._pickerTarget = null;
    renderPickBtn();
  }

  function isInsidePanel(el) {
    const root = document.getElementById("la-root");
    return root && root.contains(el);
  }

  function onHover(e) {
    if (isInsidePanel(e.target)) return;
    clearHighlight();
    state._pickerTarget = e.target;
    e.target.setAttribute("data-la-highlight", "true");
  }

  function onOut(e) {
    if (isInsidePanel(e.target)) return;
    e.target.removeAttribute("data-la-highlight");
  }

  function onClick(e) {
    if (isInsidePanel(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    const el = state._pickerTarget || e.target;
    stopPicker();
    captureElement(el);
  }

  function onKey(e) {
    if (e.key === "Escape") stopPicker();
  }

  function clearHighlight() {
    if (state._pickerTarget) {
      state._pickerTarget.removeAttribute("data-la-highlight");
    }
    document.querySelectorAll("[data-la-highlight]").forEach((el) => {
      el.removeAttribute("data-la-highlight");
    });
  }

  function captureElement(el) {
    // Collect all phx-* and data-phx-* attributes walking up the tree
    const phx = {};
    let node = el;
    while (node && node !== document.documentElement) {
      if (node.attributes) {
        for (const attr of node.attributes) {
          if (
            (attr.name.startsWith("data-phx") || attr.name.startsWith("phx-")) &&
            !(attr.name in phx)
          ) {
            phx[attr.name] = attr.value;
          }
        }
      }
      node = node.parentElement;
    }

    const parentChain = [];
    let p = el.parentElement;
    for (let i = 0; i < 5 && p && p !== document.body; i++, p = p.parentElement) {
      parentChain.push({
        tag: p.tagName.toLowerCase(),
        id: p.id || null,
        classes: Array.from(p.classList).slice(0, 5),
      });
    }

    const data = {
      tag: el.tagName.toLowerCase(),
      id: el.id || null,
      classes: Array.from(el.classList),
      text: (el.textContent || "").trim().slice(0, 300),
      outerHTML: el.outerHTML.slice(0, 4000),
      phx,
      parentChain,
      url: window.location.href,
      capturedAt: new Date().toISOString(),
    };

    state.selectedElement = data;
    state.activeTab = "selected";

    fetch(BASE + "/api/element", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data),
    }).catch(() => {});

    renderAll();
  }

  // ─── API ───────────────────────────────────────────────────────────────────

  function fetchLiveViews() {
    fetch(BASE + "/api/live_views")
      .then((r) => r.json())
      .then((views) => {
        state.liveViews = views;
        if (state.activeTab === "liveviews") renderPane("liveviews");
      })
      .catch(() => {});
  }

  function fetchAssigns(pid) {
    return fetch(BASE + "/api/assigns?pid=" + encodeURIComponent(pid))
      .then((r) => r.json())
      .catch(() => null);
  }

  function apiPin() {
    return fetch(BASE + "/api/pin", { method: "POST" }).then(() => {
      state.pinnedContext = state.selectedElement;
      renderAll();
    });
  }

  function apiClearPin() {
    return fetch(BASE + "/api/pin", { method: "DELETE" }).then(() => {
      state.pinnedContext = null;
      renderAll();
    });
  }

  // ─── Panel Init ────────────────────────────────────────────────────────────

  function init() {
    const root = document.getElementById("la-root");
    if (!root) return;

    root.innerHTML = `
      <button id="la-toggle" title="Open LiveAgent panel">&#9889; LA</button>
      <div id="la-panel">
        <div id="la-bar">
          <div id="la-tabs">
            <button class="la-tab" data-tab="liveviews">LiveViews</button>
            <button class="la-tab" data-tab="selected">Selected</button>
            <button class="la-tab" data-tab="context">Context</button>
          </div>
          <div id="la-bar-right">
            <button id="la-pick-btn">&#128269; Pick</button>
            <button id="la-resize-btn" title="Toggle height">&#8645;</button>
            <button id="la-close-btn" title="Close">&#10005;</button>
          </div>
        </div>
        <div id="la-body">
          <div id="la-pane-liveviews" class="la-pane"></div>
          <div id="la-pane-selected" class="la-pane"></div>
          <div id="la-pane-context" class="la-pane"></div>
        </div>
      </div>
    `;

    document.getElementById("la-toggle").addEventListener("click", openPanel);
    document.getElementById("la-close-btn").addEventListener("click", closePanel);
    document.getElementById("la-pick-btn").addEventListener("click", togglePicker);
    document.getElementById("la-resize-btn").addEventListener("click", toggleHeight);

    root.querySelectorAll(".la-tab").forEach((btn) => {
      btn.addEventListener("click", () => switchTab(btn.dataset.tab));
    });

    switchTab("liveviews");
  }

  // ─── Panel Controls ────────────────────────────────────────────────────────

  let tallMode = false;

  function openPanel() {
    state.visible = true;
    document.getElementById("la-panel").style.display = "flex";
    document.getElementById("la-toggle").style.display = "none";
    fetchLiveViews();
    state._pollTimer = setInterval(fetchLiveViews, 3000);
  }

  function closePanel() {
    state.visible = false;
    document.getElementById("la-panel").style.display = "none";
    document.getElementById("la-toggle").style.display = "";
    clearInterval(state._pollTimer);
    if (state.pickerActive) stopPicker();
  }

  function toggleHeight() {
    tallMode = !tallMode;
    const panel = document.getElementById("la-panel");
    panel.style.height = tallMode ? "520px" : "300px";
  }

  function togglePicker() {
    if (state.pickerActive) stopPicker();
    else startPicker();
  }

  function switchTab(tab) {
    state.activeTab = tab;
    document.querySelectorAll(".la-tab").forEach((b) =>
      b.classList.toggle("la-active", b.dataset.tab === tab)
    );
    document.querySelectorAll(".la-pane").forEach((p) => (p.style.display = "none"));
    const pane = document.getElementById("la-pane-" + tab);
    if (pane) pane.style.display = "block";
    renderPane(tab);
  }

  function renderPickBtn() {
    const btn = document.getElementById("la-pick-btn");
    if (!btn) return;
    if (state.pickerActive) {
      btn.textContent = "\u2715 Cancel";
      btn.classList.add("la-pick-active");
    } else {
      btn.innerHTML = "&#128269; Pick";
      btn.classList.remove("la-pick-active");
    }
  }

  function renderAll() {
    renderPane(state.activeTab);
    renderPickBtn();
  }

  // ─── Pane Renderers ────────────────────────────────────────────────────────

  function renderPane(tab) {
    const el = document.getElementById("la-pane-" + tab);
    if (!el) return;
    if (tab === "liveviews") el.innerHTML = renderLiveViews();
    if (tab === "selected") el.innerHTML = renderSelected();
    if (tab === "context") el.innerHTML = renderContext();
    attachPaneEvents(el, tab);
  }

  function attachPaneEvents(el, tab) {
    // Expand/collapse assigns
    el.querySelectorAll(".la-expand-btn").forEach((btn) => {
      btn.addEventListener("click", () => toggleAssigns(btn.dataset.pid, btn));
    });

    if (tab === "selected") {
      const pin = el.querySelector("#la-pin-btn");
      if (pin) pin.addEventListener("click", apiPin);
    }

    if (tab === "context") {
      const clear = el.querySelector("#la-clear-btn");
      if (clear) clear.addEventListener("click", apiClearPin);
    }
  }

  async function toggleAssigns(pid, btn) {
    const safeId = "la-assigns-" + safePidId(pid);
    const container = document.getElementById(safeId);
    if (!container) return;

    if (container.style.display !== "none" && container.innerHTML !== "") {
      container.style.display = "none";
      btn.textContent = "\u25B6";
      return;
    }

    btn.textContent = "\u25BC";
    container.style.display = "block";
    container.innerHTML = '<span class="la-dim">Loading\u2026</span>';
    const assigns = await fetchAssigns(pid);
    container.innerHTML = assigns
      ? '<pre class="la-pre">' + escHtml(JSON.stringify(assigns, null, 2)) + "</pre>"
      : '<span class="la-dim la-error">Failed to load assigns.</span>';
  }

  function renderLiveViews() {
    if (!state.liveViews.length) {
      return '<div class="la-empty">No active LiveView processes.<br><span class="la-dim">Open a LiveView page in your app.</span></div>';
    }

    return state.liveViews
      .map((v) => {
        const keys = v.assign_keys || [];
        const shown = keys.slice(0, 12);
        const extra = keys.length > 12 ? keys.length - 12 : 0;
        const safeId = safePidId(v.pid_string);

        return `<div class="la-card">
          <div class="la-card-header">
            <button class="la-expand-btn" data-pid="${escHtml(v.pid_string)}">\u25B6</button>
            <span class="la-view-name">${escHtml(shortName(v.view))}</span>
            <span class="la-badge ${v.connected ? "la-green" : "la-gray"}">${v.connected ? "live" : "static"}</span>
          </div>
          <div class="la-meta">
            <span class="la-pid">${escHtml(v.pid_string)}</span>
            ${v.url ? `<span class="la-dim la-url">${escHtml(v.url)}</span>` : ""}
          </div>
          <div class="la-chips">
            ${shown.map((k) => `<span class="la-chip">${escHtml(k)}</span>`).join("")}
            ${extra ? `<span class="la-chip la-chip-more">+${extra}</span>` : ""}
          </div>
          <div id="la-assigns-${safeId}" class="la-assigns-body" style="display:none"></div>
        </div>`;
      })
      .join("");
  }

  function renderSelected() {
    const el = state.selectedElement;
    if (!el) {
      return `<div class="la-empty">No element selected yet.<br>
        <span class="la-dim">Click <strong>&#128269; Pick</strong> then click any element on the page.</span></div>`;
    }

    const phxEntries = Object.entries(el.phx || {});
    const tag = `&lt;${escHtml(el.tag)}${el.id ? ' id="' + escHtml(el.id) + '"' : ""}${el.classes.length ? ' class="' + escHtml(el.classes.slice(0, 4).join(" ")) + '"' : ""}&gt;`;

    return `<div class="la-card">
      <div class="la-element-tag">${tag}</div>
      ${el.text ? `<div class="la-text-preview la-dim">${escHtml(el.text.slice(0, 120))}</div>` : ""}

      ${
        phxEntries.length
          ? `<div class="la-section-label">Phoenix</div>
          <div class="la-attrs">
            ${phxEntries
              .map(
                ([k, v]) =>
                  `<div class="la-attr"><span class="la-attr-k">${escHtml(k)}</span><span class="la-attr-v">${escHtml(v)}</span></div>`
              )
              .join("")}
          </div>`
          : ""
      }

      ${
        el.parentChain.length
          ? `<div class="la-section-label">Parents</div>
          <div class="la-chain">
            ${el.parentChain
              .map(
                (p) =>
                  `<span class="la-chip">${escHtml(p.tag)}${p.id ? "#" + escHtml(p.id) : ""}</span>`
              )
              .join('<span class="la-chain-sep">\u2190</span>')}
          </div>`
          : ""
      }

      <div class="la-section-label">HTML</div>
      <pre class="la-pre">${escHtml(el.outerHTML.slice(0, 2000))}</pre>

      <div class="la-actions">
        <button id="la-pin-btn" class="la-btn la-btn-primary">&#128203; Pin to Claude Context</button>
      </div>
    </div>`;
  }

  function renderContext() {
    const ctx = state.pinnedContext;
    if (!ctx) {
      return `<div class="la-empty">Nothing pinned yet.<br>
        <span class="la-dim">Select an element and click <strong>&#128203; Pin to Claude Context</strong>.</span></div>`;
    }

    const phxEntries = Object.entries(ctx.phx || {});
    const tag = `&lt;${escHtml(ctx.tag)}${ctx.id ? ' id="' + escHtml(ctx.id) + '"' : ""}&gt;`;

    return `<div class="la-card">
      <div class="la-context-badge">\u2705 Claude can read this via <code>get_pinned_context</code></div>
      <div class="la-element-tag">${tag}</div>
      <div class="la-meta">
        <span class="la-dim">${escHtml(ctx.capturedAt)}</span>
        <span class="la-dim la-url">${escHtml(ctx.url)}</span>
      </div>

      ${
        phxEntries.length
          ? `<div class="la-section-label">Phoenix</div>
          <div class="la-attrs">
            ${phxEntries
              .map(
                ([k, v]) =>
                  `<div class="la-attr"><span class="la-attr-k">${escHtml(k)}</span><span class="la-attr-v">${escHtml(v)}</span></div>`
              )
              .join("")}
          </div>`
          : ""
      }

      <div class="la-actions">
        <button id="la-clear-btn" class="la-btn la-btn-danger">&#10005; Clear</button>
      </div>
    </div>`;
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  function escHtml(str) {
    if (str == null) return "";
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function safePidId(pid) {
    return String(pid).replace(/[^a-zA-Z0-9]/g, "_");
  }

  function shortName(view) {
    // "Elixir.MyApp.SomeLive" -> "MyApp.SomeLive"
    return String(view).replace(/^Elixir\./, "");
  }

  // ─── Boot ──────────────────────────────────────────────────────────────────

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

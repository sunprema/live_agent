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
    events: [],
    lastEventId: 0,
    _eventsTimer: null,
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

  function fetchEvents() {
    fetch(BASE + "/api/events?since=" + state.lastEventId)
      .then((r) => r.json())
      .then((newEvents) => {
        if (!newEvents.length) return;
        // prepend newest events; server returns them newest-first
        state.events = newEvents.concat(state.events).slice(0, 200);
        state.lastEventId = newEvents[0].id;
        if (state.activeTab === "events") renderPane("events");
      })
      .catch(() => {});
  }

  function apiClearEvents() {
    return fetch(BASE + "/api/events", { method: "DELETE" }).then(() => {
      state.events = [];
      state.lastEventId = 0;
      renderPane("events");
    });
  }

  // ─── Panel Init ────────────────────────────────────────────────────────────

  function init() {
    const root = document.getElementById("la-root");
    if (!root) return;

    const standalone = root.dataset.laStandalone === "true";

    const newTabBtn = standalone
      ? ""
      : `<button id="la-newtab-btn" title="Open in new tab">&#8599;</button>`;

    const closeBtn = standalone
      ? ""
      : `<button id="la-close-btn" title="Close">&#10005;</button>`;

    root.innerHTML = `
      ${standalone ? "" : `<button id="la-toggle" title="Open LiveAgent panel">&#9889; LA</button>`}
      <div id="la-panel" class="${standalone ? "la-panel-standalone" : ""}">
        <div id="la-bar">
          <div id="la-tabs">
            <button class="la-tab" data-tab="liveviews">LiveViews</button>
            <button class="la-tab" data-tab="selected">Selected</button>
            <button class="la-tab" data-tab="context">Context</button>
            <button class="la-tab" data-tab="events">Events</button>
          </div>
          <div id="la-bar-right">
            <button id="la-pick-btn">&#128269; Pick</button>
            ${newTabBtn}
            ${standalone ? "" : `<button id="la-resize-btn" title="Toggle height">&#8645;</button>`}
            ${closeBtn}
          </div>
        </div>
        <div id="la-body">
          <div id="la-pane-liveviews" class="la-pane"></div>
          <div id="la-pane-selected" class="la-pane"></div>
          <div id="la-pane-context" class="la-pane"></div>
          <div id="la-pane-events" class="la-pane"></div>
        </div>
      </div>
    `;

    if (!standalone) {
      document.getElementById("la-toggle").addEventListener("click", openPanel);
      document.getElementById("la-close-btn").addEventListener("click", closePanel);
      document.getElementById("la-resize-btn").addEventListener("click", toggleHeight);
    }

    document.getElementById("la-pick-btn").addEventListener("click", togglePicker);

    const newTabEl = document.getElementById("la-newtab-btn");
    if (newTabEl) {
      newTabEl.addEventListener("click", () =>
        window.open(BASE + "/panel", "_blank", "noopener")
      );
    }

    root.querySelectorAll(".la-tab").forEach((btn) => {
      btn.addEventListener("click", () => switchTab(btn.dataset.tab));
    });

    if (standalone) {
      // In standalone mode, panel is always visible — start immediately
      state.visible = true;
      fetchLiveViews();
      state._pollTimer = setInterval(fetchLiveViews, 3000);
    }

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
    clearInterval(state._eventsTimer);
    state._eventsTimer = null;
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
    // Stop events polling when leaving events tab
    if (state.activeTab === "events" && tab !== "events") {
      clearInterval(state._eventsTimer);
      state._eventsTimer = null;
    }

    state.activeTab = tab;
    document.querySelectorAll(".la-tab").forEach((b) =>
      b.classList.toggle("la-active", b.dataset.tab === tab)
    );
    document.querySelectorAll(".la-pane").forEach((p) => (p.style.display = "none"));
    const pane = document.getElementById("la-pane-" + tab);
    if (pane) pane.style.display = "block";

    // Start events polling when entering events tab
    if (tab === "events" && !state._eventsTimer) {
      fetchEvents();
      state._eventsTimer = setInterval(fetchEvents, 1500);
    }

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
    if (tab === "events") el.innerHTML = renderEvents();
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

    if (tab === "events") {
      const clear = el.querySelector("#la-events-clear");
      if (clear) clear.addEventListener("click", apiClearEvents);

      // Expand/collapse event params on row click
      el.querySelectorAll(".la-event-row").forEach((row) => {
        row.addEventListener("click", () => {
          const params = row.nextElementSibling;
          if (params && params.classList.contains("la-event-params")) {
            params.style.display = params.style.display === "none" ? "block" : "none";
          }
        });
      });
    }
  }

  async function toggleAssigns(pid, btn) {
    const safeId = "la-assigns-" + safePidId(pid);
    const container = document.getElementById(safeId);
    if (!container) return;

    if (state.expandedPids[pid]) {
      state.expandedPids[pid] = false;
      container.style.display = "none";
      btn.textContent = "\u25B6";
      return;
    }

    state.expandedPids[pid] = true;
    btn.textContent = "\u25BC";
    container.style.display = "block";

    if (state.assignsCache[pid]) {
      container.innerHTML =
        '<pre class="la-pre">' + escHtml(JSON.stringify(state.assignsCache[pid], null, 2)) + "</pre>";
      return;
    }

    container.innerHTML = '<span class="la-dim">Loading\u2026</span>';
    const assigns = await fetchAssigns(pid);
    if (assigns) {
      state.assignsCache[pid] = assigns;
      container.innerHTML =
        '<pre class="la-pre">' + escHtml(JSON.stringify(assigns, null, 2)) + "</pre>";
    } else {
      container.innerHTML = '<span class="la-dim la-error">Failed to load assigns.</span>';
    }
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
        const expanded = !!state.expandedPids[v.pid_string];
        const cached = state.assignsCache[v.pid_string];

        const assignsBody = expanded && cached
          ? '<pre class="la-pre">' + escHtml(JSON.stringify(cached, null, 2)) + "</pre>"
          : "";

        return `<div class="la-card">
          <div class="la-card-header">
            <button class="la-expand-btn" data-pid="${escHtml(v.pid_string)}">${expanded ? "\u25BC" : "\u25B6"}</button>
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
          <div id="la-assigns-${safeId}" class="la-assigns-body" style="${expanded ? "" : "display:none"}">${assignsBody}</div>
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

  function renderEvents() {
    const toolbar = `
      <div class="la-events-toolbar">
        <span class="la-dim">${state.events.length} event${state.events.length !== 1 ? "s" : ""}</span>
        <button id="la-events-clear" class="la-btn la-btn-danger" style="padding:2px 8px;font-size:11px">Clear</button>
      </div>`;

    if (!state.events.length) {
      return toolbar + '<div class="la-empty">No events yet.<br><span class="la-dim">Interact with the app — clicks, form changes, and navigations will appear here.</span></div>';
    }

    const rows = state.events.map((ev) => {
      const isError = ev.action === "exception";
      const label = eventLabel(ev);
      const badge = eventBadge(ev, isError);
      const dur = durationBadge(ev.duration_ms, isError);
      const name = ev.event ? `<span class="la-event-name">${escHtml(ev.event)}</span>` : "";
      const uri = ev.uri ? `<span class="la-dim la-url">${escHtml(ev.uri)}</span>` : "";
      const view = ev.component
        ? escHtml(shortName(ev.component))
        : ev.view
        ? escHtml(shortName(ev.view))
        : "";
      const time = timeAgo(ev.timestamp);
      const hasDetail = ev.params || ev.error || ev.uri;

      const detail = hasDetail
        ? `<div class="la-event-params" style="display:none">
            ${ev.error ? `<div class="la-event-error">${escHtml(ev.error)}</div>` : ""}
            ${ev.params ? `<pre class="la-pre">${escHtml(JSON.stringify(ev.params, null, 2))}</pre>` : ""}
           </div>`
        : "";

      return `
        <div class="la-event-row${isError ? " la-event-row-error" : ""}${hasDetail ? " la-event-row-clickable" : ""}">
          ${badge}
          <span class="la-event-label">${label}</span>
          ${name}
          ${uri}
          <span class="la-event-view">${view}</span>
          <span class="la-event-right">${dur}<span class="la-event-time">${time}</span></span>
        </div>
        ${detail}`;
    }).join("");

    return toolbar + '<div class="la-event-list">' + rows + "</div>";
  }

  function eventLabel(ev) {
    const labels = {
      handle_event: "event",
      mount: "mount",
      handle_params: "params",
      handle_info: "info",
    };
    return labels[ev.type] || ev.type;
  }

  function eventBadge(ev, isError) {
    if (isError) return '<span class="la-ev-badge la-ev-error">error</span>';
    const cls = {
      handle_event: "la-ev-event",
      mount: "la-ev-mount",
      handle_params: "la-ev-params",
      handle_info: "la-ev-info",
    }[ev.type] || "la-ev-info";
    return `<span class="la-ev-badge ${cls}">${eventLabel(ev)}</span>`;
  }

  function durationBadge(ms, isError) {
    if (ms == null || isError) return '<span class="la-dur la-dur-nil">—</span>';
    const cls = ms < 10 ? "la-dur-fast" : ms < 100 ? "la-dur-mid" : "la-dur-slow";
    return `<span class="la-dur ${cls}">${ms}ms</span>`;
  }

  function timeAgo(iso) {
    const diff = Math.floor((Date.now() - new Date(iso)) / 1000);
    if (diff < 5) return "just now";
    if (diff < 60) return diff + "s ago";
    if (diff < 3600) return Math.floor(diff / 60) + "m ago";
    return Math.floor(diff / 3600) + "h ago";
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

(function () {
  "use strict";

  if (window.__liveAgent) return;

  const BASE = "/live_agent";

  const state = {
    visible: false,
    openPanes: ["liveviews"],
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
    ashResources: [],
    ashResourcesLoaded: false,
    expandedResources: {},
    resourceCache: {},
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

    fetch(BASE + "/api/element", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data),
    }).catch(() => {});

    if (!state.openPanes.includes("selected")) addPane("selected");
    else renderPaneContent("selected");
  }

  // ─── API ───────────────────────────────────────────────────────────────────

  function fetchLiveViews() {
    fetch(BASE + "/api/live_views")
      .then((r) => r.json())
      .then((views) => {
        state.liveViews = views;
        if (state.openPanes.includes("liveviews")) renderPaneContent("liveviews");
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
      if (!state.openPanes.includes("context")) addPane("context");
      else renderPaneContent("context");
    });
  }

  function apiClearPin() {
    return fetch(BASE + "/api/pin", { method: "DELETE" }).then(() => {
      state.pinnedContext = null;
      renderPaneContent("context");
    });
  }

  function fetchEvents() {
    fetch(BASE + "/api/events?since=" + state.lastEventId)
      .then((r) => r.json())
      .then((newEvents) => {
        if (!newEvents.length) return;
        state.events = newEvents.concat(state.events).slice(0, 200);
        state.lastEventId = newEvents[0].id;
        if (state.openPanes.includes("events")) renderPaneContent("events");
      })
      .catch(() => {});
  }

  function fetchAshResources() {
    fetch(BASE + "/api/ash_resources")
      .then((r) => r.json())
      .then((data) => {
        if (!data.error) state.ashResources = data;
      })
      .catch(() => {})
      .finally(() => {
        state.ashResourcesLoaded = true;
        if (state.openPanes.includes("resources")) renderPaneContent("resources");
      });
  }

  function fetchAshResourceInfo(name) {
    return fetch(BASE + "/api/ash_resource?name=" + encodeURIComponent(name))
      .then((r) => r.json())
      .catch(() => null);
  }

  function apiClearEvents() {
    return fetch(BASE + "/api/events", { method: "DELETE" }).then(() => {
      state.events = [];
      state.lastEventId = 0;
      renderPaneContent("events");
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
          <div id="la-launcher">
            <button class="la-launch-btn" data-pane="liveviews">LiveViews</button>
            <button class="la-launch-btn" data-pane="selected">Selected</button>
            <button class="la-launch-btn" data-pane="context">Context</button>
            <button class="la-launch-btn" data-pane="events">Events</button>
            <button class="la-launch-btn" data-pane="resources">Resources</button>
          </div>
          <div id="la-bar-right">
            <button id="la-pick-btn">&#128269; Pick</button>
            ${newTabBtn}
            ${standalone ? "" : `<button id="la-resize-btn" title="Toggle height">&#8645;</button>`}
            ${closeBtn}
          </div>
        </div>
        <div id="la-split"></div>
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

    document.querySelectorAll(".la-launch-btn").forEach((btn) => {
      btn.addEventListener("click", () => togglePane(btn.dataset.pane));
    });

    if (standalone) {
      state.visible = true;
      rebuildSplit();
      fetchLiveViews();
      state._pollTimer = setInterval(fetchLiveViews, 3000);
    }
  }

  // ─── Panel Controls ────────────────────────────────────────────────────────

  let tallMode = false;

  function openPanel() {
    state.visible = true;
    document.getElementById("la-panel").style.display = "flex";
    document.getElementById("la-toggle").style.display = "none";
    rebuildSplit();
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

  // ─── Pane Management ───────────────────────────────────────────────────────

  function paneTitle(name) {
    const titles = {
      liveviews: "LiveViews",
      selected: "Selected",
      context: "Context",
      events: "Events",
      resources: "Resources",
    };
    return titles[name] || name;
  }

  function addPane(name) {
    if (state.openPanes.includes(name)) return;
    state.openPanes.push(name);
    rebuildSplit();
    if (name === "events" && !state._eventsTimer) {
      fetchEvents();
      state._eventsTimer = setInterval(fetchEvents, 1500);
    }
    if (name === "resources" && !state.ashResourcesLoaded) {
      fetchAshResources();
    } else {
      renderPaneContent(name);
    }
    updateLauncher();
  }

  function removePane(name) {
    state.openPanes = state.openPanes.filter((p) => p !== name);
    if (name === "events" && !state.openPanes.includes("events")) {
      clearInterval(state._eventsTimer);
      state._eventsTimer = null;
    }
    rebuildSplit();
    updateLauncher();
  }

  function togglePane(name) {
    if (state.openPanes.includes(name)) removePane(name);
    else addPane(name);
  }

  function rebuildSplit() {
    const container = document.getElementById("la-split");
    if (!container) return;

    if (!state.openPanes.length) {
      container.innerHTML = '<div class="la-split-empty">Click a panel button above to open it.</div>';
      return;
    }

    container.innerHTML = state.openPanes
      .map((name, i) => {
        const isLast = i === state.openPanes.length - 1;
        const divider = isLast
          ? ""
          : `<div class="la-split-divider" data-idx="${i}"></div>`;
        return `
          <div class="la-split-pane" data-pane="${name}">
            <div class="la-pane-header">
              <span class="la-pane-title">${escHtml(paneTitle(name))}</span>
              <button class="la-pane-close" data-pane="${name}">&#10005;</button>
            </div>
            <div class="la-pane-body" id="la-pane-${name}"></div>
          </div>
          ${divider}
        `;
      })
      .join("");

    container.querySelectorAll(".la-pane-close").forEach((btn) => {
      btn.addEventListener("click", () => removePane(btn.dataset.pane));
    });

    container.querySelectorAll(".la-split-divider").forEach((div) => {
      div.addEventListener("mousedown", (e) =>
        startDividerDrag(e, parseInt(div.dataset.idx))
      );
    });

    state.openPanes.forEach((name) => renderPaneContent(name));
    updateLauncher();

    // Start events polling if events pane was just built
    if (state.openPanes.includes("events") && !state._eventsTimer) {
      fetchEvents();
      state._eventsTimer = setInterval(fetchEvents, 1500);
    }
  }

  function updateLauncher() {
    document.querySelectorAll(".la-launch-btn").forEach((btn) => {
      btn.classList.toggle("la-launch-active", state.openPanes.includes(btn.dataset.pane));
    });
  }

  // ─── Divider Drag ──────────────────────────────────────────────────────────

  let _dragState = null;

  function startDividerDrag(e, idx) {
    e.preventDefault();
    const container = document.getElementById("la-split");
    const panes = Array.from(container.querySelectorAll(".la-split-pane"));
    if (idx >= panes.length - 1) return;
    const left = panes[idx];
    const right = panes[idx + 1];
    const startX = e.clientX;
    const startLeftW = left.offsetWidth;
    const startRightW = right.offsetWidth;

    _dragState = { left, right, startX, startLeftW, startRightW };

    document.addEventListener("mousemove", onDividerMove);
    document.addEventListener("mouseup", stopDividerDrag);
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";

    // Mark active divider
    const dividers = container.querySelectorAll(".la-split-divider");
    if (dividers[idx]) dividers[idx].classList.add("la-dragging");
  }

  function onDividerMove(e) {
    if (!_dragState) return;
    const { left, right, startX, startLeftW, startRightW } = _dragState;
    const dx = e.clientX - startX;
    const minW = 120;
    let newLeftW = startLeftW + dx;
    let newRightW = startRightW - dx;
    if (newLeftW < minW) { newLeftW = minW; newRightW = startLeftW + startRightW - minW; }
    if (newRightW < minW) { newRightW = minW; newLeftW = startLeftW + startRightW - minW; }
    left.style.flexBasis = newLeftW + "px";
    left.style.flexGrow = "0";
    right.style.flexBasis = newRightW + "px";
    right.style.flexGrow = "0";
  }

  function stopDividerDrag() {
    _dragState = null;
    document.removeEventListener("mousemove", onDividerMove);
    document.removeEventListener("mouseup", stopDividerDrag);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    document.querySelectorAll(".la-split-divider.la-dragging").forEach((d) =>
      d.classList.remove("la-dragging")
    );
  }

  // ─── Pane Renderers ────────────────────────────────────────────────────────

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

  function renderPaneContent(name) {
    const el = document.getElementById("la-pane-" + name);
    if (!el) return;
    if (name === "liveviews") el.innerHTML = renderLiveViews();
    if (name === "selected") el.innerHTML = renderSelected();
    if (name === "context") el.innerHTML = renderContext();
    if (name === "events") el.innerHTML = renderEvents();
    if (name === "resources") el.innerHTML = renderResources();
    attachPaneEvents(el, name);
  }

  function attachPaneEvents(el, name) {
    el.querySelectorAll(".la-expand-btn").forEach((btn) => {
      btn.addEventListener("click", () => toggleAssigns(btn.dataset.pid, btn));
    });

    if (name === "selected") {
      const pin = el.querySelector("#la-pin-btn");
      if (pin) pin.addEventListener("click", apiPin);
    }

    if (name === "context") {
      const clear = el.querySelector("#la-clear-btn");
      if (clear) clear.addEventListener("click", apiClearPin);
    }

    if (name === "resources") {
      el.querySelectorAll(".la-res-expand-btn").forEach((btn) => {
        btn.addEventListener("click", () => toggleResource(btn.dataset.resource, btn));
      });
    }

    if (name === "events") {
      const clear = el.querySelector("#la-events-clear");
      if (clear) clear.addEventListener("click", apiClearEvents);

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

        const assignsBody =
          expanded && cached
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

  async function toggleResource(name, btn) {
    const safeId = "la-res-detail-" + name.replace(/[^a-zA-Z0-9]/g, "_");
    const container = document.getElementById(safeId);
    if (!container) return;

    if (state.expandedResources[name]) {
      state.expandedResources[name] = false;
      container.style.display = "none";
      btn.textContent = "\u25B6";
      return;
    }

    state.expandedResources[name] = true;
    btn.textContent = "\u25BC";
    container.style.display = "block";

    if (state.resourceCache[name]) {
      container.innerHTML = renderResourceDetail(state.resourceCache[name]);
      return;
    }

    container.innerHTML = '<span class="la-dim">Loading\u2026</span>';
    const info = await fetchAshResourceInfo(name);
    if (info && !info.error) {
      state.resourceCache[name] = info;
      container.innerHTML = renderResourceDetail(info);
    } else {
      container.innerHTML = '<span class="la-dim la-error">Failed to load resource info.</span>';
    }
  }

  function renderResources() {
    if (!state.ashResourcesLoaded) {
      return '<div class="la-empty">Loading\u2026</div>';
    }

    if (!state.ashResources.length) {
      return '<div class="la-empty">No Ash resources found.<br><span class="la-dim">Make sure Ash is installed and your resources are loaded.</span></div>';
    }

    return state.ashResources
      .map((r) => {
        const name = r.resource;
        const safeId = name.replace(/[^a-zA-Z0-9]/g, "_");
        const expanded = !!state.expandedResources[name];
        const cached = state.resourceCache[name];
        const attrs = (r.attribute_names || []).slice(0, 10);
        const extra =
          (r.attribute_names || []).length > 10 ? r.attribute_names.length - 10 : 0;

        return `<div class="la-card">
        <div class="la-card-header">
          <button class="la-res-expand-btn la-expand-btn" data-resource="${escHtml(name)}">${expanded ? "\u25BC" : "\u25B6"}</button>
          <span class="la-view-name">${escHtml(shortName(name))}</span>
          ${r.domain ? `<span class="la-dim la-res-domain">${escHtml(shortName(r.domain))}</span>` : ""}
        </div>
        <div class="la-chips">
          ${attrs.map((a) => `<span class="la-chip">${escHtml(a)}</span>`).join("")}
          ${extra ? `<span class="la-chip la-chip-more">+${extra}</span>` : ""}
        </div>
        <div id="la-res-detail-${safeId}" style="${expanded && cached ? "" : "display:none"}">
          ${expanded && cached ? renderResourceDetail(cached) : ""}
        </div>
      </div>`;
      })
      .join("");
  }

  function renderResourceDetail(info) {
    const attrs = info.attributes || [];
    const actions = info.actions || [];
    const rels = info.relationships || [];
    const calcs = info.calculations || [];
    const aggs = info.aggregates || [];

    const attrRows = attrs
      .map(
        (a) => `
      <tr>
        <td class="la-res-col-name">${escHtml(a.name)}</td>
        <td class="la-res-col-type">${escHtml(a.type || "?")}</td>
        <td>${a.primary_key ? '<span class="la-res-badge la-res-pk">PK</span>' : ""}</td>
        <td class="la-dim">${a.allow_nil ? "nil ok" : "required"}</td>
        <td class="la-dim">${a.writable === false ? "read-only" : ""}</td>
      </tr>`
      )
      .join("");

    const actionRows = actions
      .map((a) => {
        const accept =
          a.accept && a.accept.length
            ? `<span class="la-dim">accept: ${escHtml(a.accept.join(", "))}</span>`
            : "";
        const args =
          a.arguments && a.arguments.length
            ? `<span class="la-dim">args: ${escHtml(a.arguments.map((x) => x.name).join(", "))}</span>`
            : "";
        return `<div class="la-res-action-row">
        <span class="la-res-action-name">${escHtml(a.name)}${a.primary ? '<span class="la-res-primary">*</span>' : ""}</span>
        <span class="la-res-badge la-res-type-${escHtml(a.type)}">${escHtml(a.type)}</span>
        ${accept}${args}
      </div>`;
      })
      .join("");

    const relRows = rels
      .map(
        (r) => `
      <div class="la-res-rel-row">
        <span class="la-res-col-name">${escHtml(r.name)}</span>
        <span class="la-res-badge la-res-rel">${escHtml(r.type)}</span>
        <span class="la-dim">\u2192 ${escHtml(r.destination)}</span>
      </div>`
      )
      .join("");

    const calcRows = calcs.length
      ? calcs.map((c) => `<span class="la-chip">${escHtml(c.name)}</span>`).join("")
      : "";

    const aggRows = aggs.length
      ? aggs
          .map((a) => `<span class="la-chip">${escHtml(a.name)} (${escHtml(a.kind)})</span>`)
          .join("")
      : "";

    return `
      <div class="la-res-detail">
        <div class="la-section-label">Attributes</div>
        <table class="la-res-table">${attrRows}</table>

        <div class="la-section-label">Actions</div>
        <div class="la-res-actions">${actionRows || '<span class="la-dim">None</span>'}</div>

        <div class="la-section-label">Relationships</div>
        <div class="la-res-rels">${relRows || '<span class="la-dim">None</span>'}</div>

        ${calcs.length ? `<div class="la-section-label">Calculations</div><div class="la-chips">${calcRows}</div>` : ""}
        ${aggs.length ? `<div class="la-section-label">Aggregates</div><div class="la-chips">${aggRows}</div>` : ""}
      </div>`;
  }

  function renderEvents() {
    const toolbar = `
      <div class="la-events-toolbar">
        <span class="la-dim">${state.events.length} event${state.events.length !== 1 ? "s" : ""}</span>
        <button id="la-events-clear" class="la-btn la-btn-danger" style="padding:2px 8px;font-size:11px">Clear</button>
      </div>`;

    if (!state.events.length) {
      return (
        toolbar +
        '<div class="la-empty">No events yet.<br><span class="la-dim">Interact with the app — clicks, form changes, and navigations will appear here.</span></div>'
      );
    }

    const rows = state.events
      .map((ev) => {
        const isError = ev.action === "exception";
        const label = eventLabel(ev);
        const badge = eventBadge(ev, isError);
        const dur = durationBadge(ev.duration_ms, isError);
        const name = ev.event
          ? `<span class="la-event-name">${escHtml(ev.event)}</span>`
          : "";
        const uri = ev.uri
          ? `<span class="la-dim la-url">${escHtml(ev.uri)}</span>`
          : "";
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
      })
      .join("");

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
    const cls =
      {
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
    return String(view).replace(/^Elixir\./, "");
  }

  // ─── Boot ──────────────────────────────────────────────────────────────────

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

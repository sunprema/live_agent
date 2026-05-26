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
    selectedComponent: null,
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
    timeline: [],
    expandedTimelineEntries: {},
    _timelineTimer: null,
    async: [],
    expandedAsyncEntries: {},
    _asyncTimer: null,
    _asyncElapsedTimer: null,
    _commandLoopActive: false,
    _commandStatus: "idle", // "idle" | "connected" | "executing" | "error"
    driveEnabled: false,
    hideUnknownTimeline: false,
    statusbarMode: false,
    screenshots: [], // {id, ts, dataUrl, width, height, selector}
  };

  const SCREENSHOT_HISTORY_LIMIT = 12;

  // Per-page-load identifier. Server-side LiveAgent.PanelStatus uses this to
  // detect "I'm talking to a fresh panel after a reload" — every time this
  // module loads, it picks a new generation, and the server resets its
  // first_seen_at to the moment it observes the change.
  const PANEL_GENERATION =
    (window.crypto && typeof window.crypto.randomUUID === "function")
      ? window.crypto.randomUUID()
      : "p-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);

  try {
    const root = document.getElementById("la-root");
    const storedDrive = localStorage.getItem("la-drive-enabled");
    if (storedDrive === null) {
      // No user preference yet — fall back to the server-configured default
      // (set via `plug LiveAgent, drive_default: true`).
      state.driveEnabled = root && root.dataset.driveDefault === "1";
    } else {
      state.driveEnabled = storedDrive === "1";
    }

    const storedOpen = localStorage.getItem("la-panel-open");
    if (storedOpen === null) {
      // Likewise for the panel's open-by-default behavior
      // (set via `plug LiveAgent, open_default: true`).
      state.openByDefault = !!(root && root.dataset.openDefault === "1");
    } else {
      state.openByDefault = storedOpen === "1";
    }

    state.hideUnknownTimeline = localStorage.getItem("la-hide-unknown-timeline") === "1";
    state.statusbarMode = localStorage.getItem("la-statusbar-mode") === "1";
  } catch (_) {
    // localStorage can throw in sandboxed contexts; default to off.
  }

  window.__liveAgent = { state };

  // ─── Error capture ────────────────────────────────────────────────────────
  // Runs immediately on script load — before the panel is opened — so no errors
  // are missed. Deduplicates bursts (same message within 500ms → dropped).

  (function () {
    let _lastMsg = null, _lastTs = 0;

    function postError(payload) {
      const now = Date.now();
      if (payload.message === _lastMsg && now - _lastTs < 500) return;
      _lastMsg = payload.message;
      _lastTs = now;
      payload.timestamp = new Date().toISOString();
      fetch(BASE + "/api/errors", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        keepalive: true,
      }).catch(() => {});
    }

    const _origOnError = window.onerror;
    window.onerror = function (message, filename, lineno, colno, error) {
      postError({
        type: "error",
        message: String(message),
        filename: filename || null,
        lineno: lineno || null,
        colno: colno || null,
        stack: error && error.stack ? String(error.stack) : null,
      });
      return _origOnError ? _origOnError.apply(this, arguments) : false;
    };

    window.addEventListener("unhandledrejection", function (e) {
      const reason = e.reason;
      postError({
        type: "unhandledrejection",
        message: reason instanceof Error ? reason.message : String(reason),
        stack: reason instanceof Error && reason.stack ? String(reason.stack) : null,
        filename: null,
        lineno: null,
        colno: null,
      });
    });
  })();

  // ─── Console capture ───────────────────────────────────────────────────────
  // Wraps console.{log,info,warn,error,debug} so MCP callers can pull a tail
  // of the host page's browser console without asking the user to open
  // devtools. Saves originals first so devtools still shows everything live,
  // and so panel-internal code can opt out by using `nativeConsole.*`.
  //
  // Entries are batched and POSTed to /api/console every 250ms (or sooner if
  // the local buffer fills up). On page hide/unload, we flush via sendBeacon
  // so logs from the moments before a reload aren't lost.

  const nativeConsole = {
    log: console.log.bind(console),
    info: console.info.bind(console),
    warn: console.warn.bind(console),
    error: console.error.bind(console),
    debug: console.debug ? console.debug.bind(console) : console.log.bind(console),
  };

  (function () {
    const LEVELS = ["log", "info", "warn", "error", "debug"];
    const MAX_BUFFER = 200;
    const FLUSH_INTERVAL_MS = 250;
    const FLUSH_AT_SIZE = 50;
    const ARG_CHAR_LIMIT = 1000;

    const buffer = [];
    let flushTimer = null;

    function serializeArg(arg) {
      if (arg === null) return "null";
      if (arg === undefined) return "undefined";
      if (typeof arg === "string") return arg;
      if (typeof arg === "number" || typeof arg === "boolean") return String(arg);
      if (arg instanceof Error) {
        return arg.stack ? arg.message + "\n" + arg.stack : arg.message;
      }
      try {
        return JSON.stringify(arg, replacerWithCycleGuard());
      } catch (_) {
        try { return String(arg); } catch (__) { return "[unserializable]"; }
      }
    }

    function replacerWithCycleGuard() {
      const seen = new WeakSet();
      return function (_key, value) {
        if (typeof value === "object" && value !== null) {
          if (seen.has(value)) return "[circular]";
          seen.add(value);
        }
        return value;
      };
    }

    function record(level, args) {
      const parts = [];
      for (let i = 0; i < args.length; i++) {
        let s = serializeArg(args[i]);
        if (s.length > ARG_CHAR_LIMIT) s = s.slice(0, ARG_CHAR_LIMIT) + "…";
        parts.push(s);
      }
      buffer.push({
        level,
        message: parts.join(" "),
        url: location.pathname + location.search,
        timestamp: new Date().toISOString(),
      });
      // bound memory if the server's down
      if (buffer.length > MAX_BUFFER) buffer.splice(0, buffer.length - MAX_BUFFER);
      if (buffer.length >= FLUSH_AT_SIZE) scheduleFlush(0);
      else scheduleFlush(FLUSH_INTERVAL_MS);
    }

    function scheduleFlush(delay) {
      if (flushTimer) return;
      flushTimer = setTimeout(flush, delay);
    }

    function flush() {
      flushTimer = null;
      if (buffer.length === 0) return;
      const entries = buffer.splice(0, buffer.length);
      fetch(BASE + "/api/console", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ entries }),
        keepalive: true,
      }).catch(() => {});
    }

    function beaconFlush() {
      if (buffer.length === 0) return;
      const entries = buffer.splice(0, buffer.length);
      const body = JSON.stringify({ entries });
      if (navigator.sendBeacon) {
        try {
          const blob = new Blob([body], { type: "application/json" });
          navigator.sendBeacon(BASE + "/api/console", blob);
          return;
        } catch (_) { /* fall through */ }
      }
      fetch(BASE + "/api/console", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        keepalive: true,
      }).catch(() => {});
    }

    for (const level of LEVELS) {
      const orig = nativeConsole[level];
      console[level] = function () {
        try { record(level, arguments); } catch (_) { /* never break console */ }
        orig.apply(console, arguments);
      };
    }

    window.addEventListener("pagehide", beaconFlush);
    window.addEventListener("beforeunload", beaconFlush);
  })();

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
    state.selectedComponent = null;

    fetch(BASE + "/api/element", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data),
    })
      .then((r) => r.json())
      .then((resp) => {
        if (resp.component) {
          state.selectedComponent = resp.component;
          if (state.openPanes.includes("selected")) renderPaneContent("selected");
        }
      })
      .catch(() => {});

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

  function fetchTimeline() {
    fetch(BASE + "/api/state_timeline?last_n=20")
      .then((r) => r.json())
      .then((data) => {
        state.timeline = Array.isArray(data) ? data : [];
        if (state.openPanes.includes("timeline")) renderPaneContent("timeline");
      })
      .catch(() => {});
  }

  function fetchAsync() {
    fetch(BASE + "/api/async")
      .then((r) => r.json())
      .then((data) => {
        state.async = Array.isArray(data) ? data : [];
        if (state.openPanes.includes("async")) renderPaneContent("async");
      })
      .catch(() => {});
  }

  function tickAsyncElapsed() {
    // Update the elapsed-time text on pending rows without a full re-render.
    document.querySelectorAll("[data-async-started]").forEach((el) => {
      const started = Number(el.dataset.asyncStarted);
      if (!started) return;
      const ms = Date.now() - started;
      el.textContent = formatElapsed(ms);
    });
  }

  function formatElapsed(ms) {
    if (ms < 1000) return ms + "ms";
    if (ms < 60_000) return (ms / 1000).toFixed(1) + "s";
    return Math.floor(ms / 60_000) + "m" + Math.floor((ms % 60_000) / 1000) + "s";
  }

  // ─── Agent Command Loop ────────────────────────────────────────────────────

  // Snapshot the panel/page readiness signals the server cares about.
  // Used both as a piggyback on /api/commands polls (so the server learns the
  // panel's state on every long-poll) and as the body of the /api/hello POST
  // we fire once on boot. Keys mirror PanelStatus.report/1.
  function readinessParams() {
    let lvConnected = false;
    try {
      lvConnected = !!(window.liveSocket && window.liveSocket.isConnected && window.liveSocket.isConnected());
    } catch (_) { /* liveSocket might not exist on non-LV pages */ }

    return {
      gen: PANEL_GENERATION,
      doc: document.readyState === "complete" ? "1" : "0",
      lv: lvConnected ? "1" : "0",
      main: document.querySelector("[data-phx-main]") ? "1" : "0",
      url: location.pathname + location.search,
    };
  }

  function readinessQueryString() {
    const p = readinessParams();
    return "?" + Object.keys(p)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(p[k]))
      .join("&");
  }

  // Fire-and-forget "I'm here" beacon so PanelStatus learns about a new
  // page-load before the first long-poll completes. Without this, the server
  // would only learn the panel is back when /api/commands eventually returns
  // (or hits its 25s timeout), which leaves a measurable readiness gap after
  // a Phoenix hot-reload.
  function postHello() {
    try {
      fetch(BASE + "/api/hello", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(readinessParams()),
        keepalive: true,
      }).catch(() => {});
    } catch (_) {}
  }

  function setCommandStatus(status) {
    state._commandStatus = status;
    const pill = document.getElementById("la-cmd-pill");
    if (!pill) return;
    pill.className = "la-cmd-pill la-cmd-" + status;
    const titles = {
      idle: "Agent control: not connected",
      connected: "Agent control: connected (waiting for commands)",
      executing: "Agent control: executing command",
      error: "Agent control: error — reconnecting",
    };
    pill.title = titles[status] || status;
  }

  function startCommandLoop() {
    if (state._commandLoopActive) return;
    state._commandLoopActive = true;
    setCommandStatus("connected");
    commandPoll();
  }

  function stopCommandLoop() {
    state._commandLoopActive = false;
    setCommandStatus("idle");
  }

  function commandPoll() {
    if (!state._commandLoopActive) return;

    fetch(BASE + "/api/commands" + readinessQueryString())
      .then((r) => {
        if (!r.ok) throw new Error("poll status " + r.status);
        return r.json();
      })
      .then((commands) => {
        setCommandStatus("connected");
        if (Array.isArray(commands) && commands.length > 0) {
          // Execute serially so results stay correlated.
          return commands.reduce(
            (chain, cmd) => chain.then(() => executeCommand(cmd)),
            Promise.resolve()
          );
        }
      })
      .catch((err) => {
        nativeConsole.warn("[live_agent] command poll failed:", err);
        setCommandStatus("error");
        return new Promise((res) => setTimeout(res, 2000));
      })
      .then(() => {
        if (state._commandLoopActive) commandPoll();
      });
  }

  function executeCommand(cmd) {
    setCommandStatus("executing");
    return runCommandOp(cmd)
      .then((result) => postCommandResult(cmd.id, { ok: true, ...result }))
      .catch((err) =>
        postCommandResult(cmd.id, { ok: false, error: String(err && err.message || err) })
      )
      .then(() => setCommandStatus("connected"));
  }

  // Dispatch table for browser-executed commands. Each entry receives the
  // command args and returns a result object (merged into `{ok:true, ...}`
  // when posting back). Throw to report a failure.
  const commandOps = {
    highlight: cmdHighlight,
    clear_highlight: cmdClearHighlight,
    click: cmdClick,
    navigate: cmdNavigate,
    fill: cmdFill,
    submit: cmdSubmit,
    wait_for: cmdWaitFor,
    screenshot: cmdScreenshot,
    screenshot_diff: cmdScreenshotDiff,
    act_as: cmdActAs,
    inject_css: cmdInjectCss,
    revert_css: cmdRevertCss,
    scroll_to: cmdScrollTo,
    get_computed_styles: cmdGetComputedStyles,
  };

  // Ops that mutate the page; gated behind the Drive toggle.
  const driveOps = new Set(["click", "navigate", "fill", "submit", "act_as"]);

  // ─── Highlight overlay ─────────────────────────────────────────────────────

  let highlightTimer = null;

  function isInsideLAPanel(el) {
    const panel = document.getElementById("la-root");
    return panel && panel.contains(el);
  }

  function resolveTarget(args) {
    if (args.cid != null) {
      return Array.from(
        document.querySelectorAll('[data-phx-component="' + args.cid + '"]')
      ).filter((el) => !isInsideLAPanel(el));
    }

    if (args.selector) {
      return Array.from(document.querySelectorAll(args.selector)).filter(
        (el) => !isInsideLAPanel(el)
      );
    }

    if (args.text) {
      return findByText(args.text);
    }

    return [];
  }

  function findByText(text) {
    const t = text.trim().toLowerCase();
    if (!t) return [];

    const clickableSel =
      "button, a, [phx-click], [role='button'], label, input[type='submit'], input[type='button']";

    for (const el of document.querySelectorAll(clickableSel)) {
      if (isInsideLAPanel(el)) continue;
      const txt = (el.textContent || el.value || "").trim().toLowerCase();
      if (txt && txt.includes(t)) return [el];
    }

    // Fallback: any element with direct text node matching, deepest first.
    const matches = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    while (walker.nextNode()) {
      const el = walker.currentNode;
      if (isInsideLAPanel(el)) continue;
      const direct = Array.from(el.childNodes)
        .filter((n) => n.nodeType === 3)
        .map((n) => n.textContent.trim().toLowerCase())
        .join(" ");
      if (direct.includes(t)) matches.push(el);
    }
    return matches.slice(-5).reverse();
  }

  function describeElement(el) {
    let s = el.tagName.toLowerCase();
    if (el.id) s += "#" + el.id;
    if (typeof el.className === "string") {
      const cls = el.className.trim().split(/\s+/).filter(Boolean).slice(0, 2);
      if (cls.length) s += "." + cls.join(".");
    }
    return s;
  }

  function summarizeElement(el) {
    const phx = {};
    if (el.attributes) {
      for (const a of el.attributes) {
        if (a.name.startsWith("phx-") || a.name.startsWith("data-phx-")) {
          phx[a.name] = a.value;
        }
      }
    }
    return {
      tag: el.tagName.toLowerCase(),
      id: el.id || null,
      classes: typeof el.className === "string"
        ? el.className.trim().split(/\s+/).filter(Boolean)
        : [],
      text: (el.textContent || "").trim().slice(0, 120),
      phx,
    };
  }

  function clearHighlightOverlay() {
    if (highlightTimer) {
      clearTimeout(highlightTimer);
      highlightTimer = null;
    }
    const existing = document.getElementById("la-highlight-overlay");
    if (existing) existing.remove();
  }

  function drawHighlight(el, label) {
    clearHighlightOverlay();

    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return rect;

    const cs = getComputedStyle(el);
    const m = {
      t: parseFloat(cs.marginTop) || 0,
      r: parseFloat(cs.marginRight) || 0,
      b: parseFloat(cs.marginBottom) || 0,
      l: parseFloat(cs.marginLeft) || 0,
    };

    const overlay = document.createElement("div");
    overlay.id = "la-highlight-overlay";

    const band = (cls, x, y, w, h) => {
      const d = document.createElement("div");
      d.className = "la-hi-band " + cls;
      d.style.left = x + "px";
      d.style.top = y + "px";
      d.style.width = w + "px";
      d.style.height = h + "px";
      return d;
    };

    if (m.t + m.r + m.b + m.l > 0) {
      overlay.appendChild(
        band(
          "la-hi-margin",
          rect.left - m.l,
          rect.top - m.t,
          rect.width + m.l + m.r,
          rect.height + m.t + m.b
        )
      );
    }
    overlay.appendChild(band("la-hi-element", rect.left, rect.top, rect.width, rect.height));

    const tip = document.createElement("div");
    tip.className = "la-hi-tip";
    tip.textContent = label || describeElement(el);
    const tipTop = rect.top > 30 ? rect.top - 22 : rect.bottom + 4;
    tip.style.left = Math.max(0, rect.left) + "px";
    tip.style.top = tipTop + "px";
    overlay.appendChild(tip);

    document.body.appendChild(overlay);
    return rect;
  }

  function cmdHighlight(args) {
    const nodes = resolveTarget(args || {});
    if (nodes.length === 0) {
      return { matched_count: 0, rect: null, resolved: null };
    }

    const el = nodes[0];
    el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
    const rect = drawHighlight(el, args.label);

    const duration = args.duration_ms != null ? args.duration_ms : 3000;
    if (duration > 0) {
      highlightTimer = setTimeout(clearHighlightOverlay, duration);
    }

    return {
      matched_count: nodes.length,
      rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height },
      resolved: summarizeElement(el),
    };
  }

  function cmdClearHighlight() {
    clearHighlightOverlay();
    return {};
  }

  // ─── Drive: click + navigate ───────────────────────────────────────────────

  // Wait for the next batch of DOM mutations to settle, or `timeoutMs`,
  // whichever comes first. Used after click/navigate so the post-action
  // snapshot reflects the LV patch that the event triggered.
  function waitForPatch(timeoutMs) {
    return new Promise((resolve) => {
      let settleTimer = null;
      const settle = () => {
        obs.disconnect();
        clearTimeout(settleTimer);
        clearTimeout(capTimer);
        resolve();
      };
      const obs = new MutationObserver(() => {
        clearTimeout(settleTimer);
        settleTimer = setTimeout(settle, 120);
      });
      obs.observe(document.body, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
      });
      const capTimer = setTimeout(settle, timeoutMs);
    });
  }

  function currentMainView() {
    const el =
      document.querySelector("[data-phx-main]") ||
      document.querySelector("[data-phx-session]");
    if (!el) return null;
    return {
      id: el.id || null,
      session_present: el.hasAttribute("data-phx-session"),
    };
  }

  function captureFlash() {
    const flashes = [];
    const seen = new Set();
    document
      .querySelectorAll(
        "[role='alert'], [phx-flash], [data-flash], #flash-info, #flash-error, .flash, .alert"
      )
      .forEach((el) => {
        if (seen.has(el)) return;
        seen.add(el);
        // Phoenix's stock disconnect templates (#client-error, #server-error)
        // and any other flash containers that are present-but-hidden are not
        // real flashes — they'd otherwise spam every click/navigate response.
        if (!isVisible(el)) return;
        const text = (el.textContent || "").trim();
        if (!text) return;
        flashes.push({
          kind:
            el.getAttribute("phx-flash") ||
            el.getAttribute("data-flash") ||
            el.id ||
            el.className ||
            "alert",
          text: text.slice(0, 240),
        });
      });
    return flashes;
  }

  function isVisible(el) {
    if (el.hidden) return false;
    const style = window.getComputedStyle(el);
    if (style.display === "none") return false;
    if (style.visibility === "hidden") return false;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return false;
    return true;
  }

  function cmdClick(args) {
    const nodes = resolveTarget(args || {});
    if (nodes.length === 0) {
      throw new Error("no element matched the given target");
    }
    const el = nodes[0];

    const urlBefore = location.href;
    const viewBefore = currentMainView();

    el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
    el.click();

    return waitForPatch(2000).then(() => ({
      matched_count: nodes.length,
      resolved: summarizeElement(el),
      url_before: urlBefore,
      url_after: location.href,
      view_before: viewBefore,
      view_after: currentMainView(),
      flash: captureFlash(),
    }));
  }

  function parseBool(v) {
    if (typeof v === "boolean") return v;
    if (typeof v === "number") return v !== 0;
    const s = String(v).trim().toLowerCase();
    return s === "true" || s === "1" || s === "on" || s === "yes" || s === "checked";
  }

  function cmdFill(args) {
    const nodes = resolveTarget(args || {});
    if (nodes.length === 0) throw new Error("no element matched");
    const el = nodes[0];

    const isCheckable = el.type === "checkbox" || el.type === "radio";
    const isContentEditable = el.isContentEditable;

    if (!isCheckable && !isContentEditable && !("value" in el)) {
      throw new Error("element does not accept input: " + describeElement(el));
    }

    const value = args.value != null ? args.value : "";

    el.focus();

    if (isCheckable) {
      const target = parseBool(value);
      if (el.checked !== target) {
        el.checked = target;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }
    } else if (isContentEditable) {
      el.textContent = value;
      el.dispatchEvent(new InputEvent("input", { bubbles: true }));
    } else {
      el.value = value;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }

    return waitForPatch(2000).then(() => ({
      resolved: summarizeElement(el),
      new_value: isCheckable
        ? el.checked
        : isContentEditable
        ? el.textContent
        : el.value,
      flash: captureFlash(),
    }));
  }

  function cmdSubmit(args) {
    const nodes = resolveTarget(args || {});
    if (nodes.length === 0) throw new Error("no element matched");
    const el = nodes[0];
    const form = el.tagName === "FORM" ? el : el.closest("form");
    if (!form) {
      throw new Error("no <form> ancestor found for " + describeElement(el));
    }

    const urlBefore = location.href;
    const viewBefore = currentMainView();

    if (typeof form.requestSubmit === "function") {
      form.requestSubmit();
    } else {
      form.submit();
    }

    return waitForPatch(2000).then(() => ({
      form: summarizeElement(form),
      url_before: urlBefore,
      url_after: location.href,
      view_before: viewBefore,
      view_after: currentMainView(),
      flash: captureFlash(),
    }));
  }

  function cmdWaitFor(args) {
    const timeout = args.timeout_ms || 5000;
    if (args.selector) return waitForSelector(args.selector, timeout);
    if (args.text) return waitForText(args.text, timeout);
    throw new Error("wait_for (browser) requires 'selector' or 'text'");
  }

  function waitForSelector(selector, timeout) {
    return new Promise((resolve, reject) => {
      const tryFind = () => {
        const found = document.querySelector(selector);
        return found && !isInsideLAPanel(found) ? found : null;
      };

      const existing = tryFind();
      if (existing) {
        resolve({
          mode: "selector",
          selector,
          found: true,
          waited_ms: 0,
          summary: summarizeElement(existing),
        });
        return;
      }

      const start = performance.now();
      const obs = new MutationObserver(() => {
        const found = tryFind();
        if (found) {
          obs.disconnect();
          clearTimeout(cap);
          resolve({
            mode: "selector",
            selector,
            found: true,
            waited_ms: Math.round(performance.now() - start),
            summary: summarizeElement(found),
          });
        }
      });
      obs.observe(document.body, { childList: true, subtree: true, attributes: true });
      const cap = setTimeout(() => {
        obs.disconnect();
        reject(new Error("timeout waiting for selector: " + selector));
      }, timeout);
    });
  }

  function waitForText(text, timeout) {
    return new Promise((resolve, reject) => {
      const t = text.toLowerCase();
      const start = performance.now();

      const check = () => {
        const body = (document.body.innerText || "").toLowerCase();
        return body.includes(t);
      };

      if (check()) {
        resolve({ mode: "text", text, found: true, waited_ms: 0 });
        return;
      }

      const obs = new MutationObserver(() => {
        if (check()) {
          obs.disconnect();
          clearTimeout(cap);
          resolve({
            mode: "text",
            text,
            found: true,
            waited_ms: Math.round(performance.now() - start),
          });
        }
      });
      obs.observe(document.body, {
        childList: true,
        subtree: true,
        characterData: true,
      });
      const cap = setTimeout(() => {
        obs.disconnect();
        reject(new Error("timeout waiting for text: " + text));
      }, timeout);
    });
  }

  function cmdNavigate(args) {
    const path = (args && args.path) || "";
    if (!path) throw new Error("navigate requires a 'path'");

    const mode = (args && args.mode) || "patch"; // "patch" | "navigate" | "href"
    const urlBefore = location.href;
    const viewBefore = currentMainView();

    if (mode === "href" || !window.liveSocket) {
      window.location.assign(path);
      return {
        mode: "href",
        url_before: urlBefore,
        url_after: path,
        view_before: viewBefore,
        view_after: null,
        note: "Full-page navigation; the panel will reconnect after reload.",
      };
    }

    // Synthesize an LV link click — Phoenix LiveView's delegated click
    // handler picks up [data-phx-link] and routes via the channel.
    const a = document.createElement("a");
    a.href = path;
    a.setAttribute("data-phx-link", mode === "patch" ? "patch" : "redirect");
    a.setAttribute("data-phx-link-state", "push");
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    a.remove();

    return waitForPatch(2000).then(() => ({
      mode,
      url_before: urlBefore,
      url_after: location.href,
      view_before: viewBefore,
      view_after: currentMainView(),
      flash: captureFlash(),
    }));
  }

  // Impersonation: POST the identifier to the dev-only act_as route (which calls
  // the app's sign-in closure and writes the session cookie), then reload so the
  // LiveSocket reconnects authenticated. We post the command result first and
  // reload on a short delay so the result reaches the server before navigation
  // tears the page down (same race the href-navigate path relies on). The MCP
  // tool confirms the new actor server-side by reading the reconnected scope.
  async function cmdActAs(args) {
    const identifier = args && args.identifier;
    if (!identifier) throw new Error("act_as requires an 'identifier'");

    const res = await fetch(BASE + "/act_as", {
      method: "POST",
      headers: { "content-type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify({ identifier }),
    });

    let data = {};
    try {
      data = await res.json();
    } catch (_e) {
      // fall through to the status check below
    }

    if (!res.ok || data.ok === false) {
      throw new Error(data.error || "act_as failed (HTTP " + res.status + ")");
    }

    setTimeout(() => window.location.reload(), 100);
    return { who: data.who, note: "Session set; reloading to reconnect as the new actor." };
  }

  // ─── Screenshot ───────────────────────────────────────────────────────────
  //
  // Primary fix: html2canvas-pro is the maintained fork of html2canvas with
  // native support for oklch/oklab/lch/lab/color() — modern Tailwind v4 and
  // DaisyUI builds emit oklch() everywhere, and the original html2canvas
  // v1.4.1 dies with "unsupported color function" on them.
  //
  // Belt-and-suspenders: before invoking the lib, we still walk same-origin
  // stylesheets (including @media/@supports/@layer and adoptedStyleSheets)
  // and rewrite oklch()/oklab() to their sRGB equivalents. This uses
  // style.cssText (which always contains custom properties like
  // --color-primary, regardless of how style[i] enumeration behaves in the
  // browser) so DaisyUI's --color-* palette gets patched at its definition
  // site, and downstream var(--color-*) lookups recompute to rgb for free.
  // Originals are restored in finally{}.

  function oklabToSrgbString(L, a, b, A) {
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    const ll = l_ ** 3, mm = m_ ** 3, ss = s_ ** 3;
    const lr = 4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss;
    const lg = -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss;
    const lb = -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss;
    const toSrgb = (c) => {
      c = Math.max(0, Math.min(1, c));
      const v = c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
      return Math.round(v * 255);
    };
    const r = toSrgb(lr), g = toSrgb(lg), bb = toSrgb(lb);
    if (A >= 1) return `rgb(${r}, ${g}, ${bb})`;
    return `rgba(${r}, ${g}, ${bb}, ${Number(A.toFixed(3))})`;
  }

  function parseNum01(s, fallback = 0) {
    if (!s || s === "none") return fallback;
    if (s.endsWith("%")) return parseFloat(s) / 100;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : fallback;
  }

  function parseChroma(s) {
    if (!s || s === "none") return 0;
    if (s.endsWith("%")) return (parseFloat(s) / 100) * 0.4;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : 0;
  }

  function parseAxis(s) {
    if (!s || s === "none") return 0;
    if (s.endsWith("%")) return (parseFloat(s) / 100) * 0.4;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : 0;
  }

  function parseHueDeg(s) {
    if (!s || s === "none") return 0;
    if (s.endsWith("deg")) return parseFloat(s);
    if (s.endsWith("rad")) return (parseFloat(s) * 180) / Math.PI;
    if (s.endsWith("turn")) return parseFloat(s) * 360;
    if (s.endsWith("grad")) return parseFloat(s) * 0.9;
    return parseFloat(s) || 0;
  }

  function parseAlphaStr(s) {
    if (!s || s === "none") return 1;
    if (s.endsWith("%")) return parseFloat(s) / 100;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : 1;
  }

  function convertOklchToken(segment) {
    // segment looks like "oklch(L C H)" or "oklch(L C H / A)"
    const open = segment.indexOf("(");
    const inner = segment.slice(open + 1, segment.length - 1);
    const [coordsRaw, alphaRaw] = inner.split("/");
    const parts = coordsRaw.trim().split(/\s+/);
    if (parts.length < 3) return null;
    const L = parseNum01(parts[0]);
    const C = parseChroma(parts[1]);
    const H = parseHueDeg(parts[2]);
    const A = alphaRaw !== undefined ? parseAlphaStr(alphaRaw.trim()) : 1;
    const a = C * Math.cos((H * Math.PI) / 180);
    const b = C * Math.sin((H * Math.PI) / 180);
    return oklabToSrgbString(L, a, b, A);
  }

  function convertOklabToken(segment) {
    const open = segment.indexOf("(");
    const inner = segment.slice(open + 1, segment.length - 1);
    const [coordsRaw, alphaRaw] = inner.split("/");
    const parts = coordsRaw.trim().split(/\s+/);
    if (parts.length < 3) return null;
    const L = parseNum01(parts[0]);
    const a = parseAxis(parts[1]);
    const b = parseAxis(parts[2]);
    const A = alphaRaw !== undefined ? parseAlphaStr(alphaRaw.trim()) : 1;
    return oklabToSrgbString(L, a, b, A);
  }

  function replaceModernColors(val) {
    if (!val || (!val.includes("oklch(") && !val.includes("oklab("))) return null;
    let out = "";
    let i = 0;
    let changed = false;
    while (i < val.length) {
      const oklchIdx = val.indexOf("oklch(", i);
      const oklabIdx = val.indexOf("oklab(", i);
      let start = -1;
      let fn = null;
      if (oklchIdx !== -1 && (oklabIdx === -1 || oklchIdx < oklabIdx)) {
        start = oklchIdx;
        fn = "oklch";
      } else if (oklabIdx !== -1) {
        start = oklabIdx;
        fn = "oklab";
      }
      if (start === -1) {
        out += val.slice(i);
        break;
      }
      out += val.slice(i, start);
      // Walk to matching close paren (handles one level of nesting like calc()).
      let depth = 0;
      let j = start + fn.length; // points at "("
      for (; j < val.length; j++) {
        const ch = val[j];
        if (ch === "(") depth++;
        else if (ch === ")") {
          depth--;
          if (depth === 0) { j++; break; }
        }
      }
      const segment = val.slice(start, j);
      const rgb = fn === "oklch" ? convertOklchToken(segment) : convertOklabToken(segment);
      if (rgb) { out += rgb; changed = true; } else out += segment;
      i = j;
    }
    return changed ? out : null;
  }

  function patchStylesheetsForCapture() {
    const patches = [];
    const visit = (rules) => {
      if (!rules) return;
      for (const rule of rules) {
        if (rule.cssRules) visit(rule.cssRules); // @media, @supports, @layer
        const style = rule.style;
        if (!style) continue;
        const text = style.cssText;
        if (!text || (!text.includes("oklch(") && !text.includes("oklab("))) continue;
        const replaced = replaceModernColors(text);
        if (!replaced || replaced === text) continue;
        patches.push({ style, original: text });
        try {
          style.cssText = replaced;
        } catch (_) {
          // Browser rejected the patched text — drop the patch entry so we
          // don't try to revert a write that never happened.
          patches.pop();
        }
      }
    };
    const sheets = [
      ...document.styleSheets,
      ...(document.adoptedStyleSheets || []),
    ];
    for (const sheet of sheets) {
      let rules = null;
      try { rules = sheet.cssRules; } catch (_) { continue; } // CORS-blocked
      visit(rules);
    }
    return patches;
  }

  function revertStylesheetPatches(patches) {
    for (const { style, original } of patches) {
      try { style.cssText = original; } catch (_) {}
    }
  }

  // html2canvas-pro exposes the same window.html2canvas global as the
  // original lib, so existing callsites keep working. If the user already
  // loaded a non-pro build, we leave it alone — the patcher above is the
  // safety net for that case.
  async function ensureHtml2Canvas() {
    if (window.html2canvas) return;
    await new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "https://cdn.jsdelivr.net/npm/html2canvas-pro@1.5.10/dist/html2canvas-pro.min.js";
      s.onload = resolve;
      s.onerror = () => reject(new Error("Failed to load html2canvas-pro"));
      document.head.appendChild(s);
    });
  }

  // Resolves a capture target from {cid|selector|text}. An explicit target
  // that matches nothing is an error (so the caller knows the clip failed);
  // with no target given we capture the whole document.
  function resolveCaptureTarget(args) {
    const explicit = args && (args.cid != null || args.selector || args.text);
    if (!explicit) return { el: document.documentElement, clipped: false };
    const matches = resolveTarget(args);
    if (!matches || matches.length === 0) {
      throw new Error("No element found for capture target: " + JSON.stringify(args));
    }
    return { el: matches[0], clipped: true };
  }

  // The single capture path shared by take_screenshot, screenshot_baseline,
  // and screenshot_diff — so palette handling (oklch) and clipping stay
  // identical across all three. Returns the html2canvas canvas plus the
  // captured rect (null for a full-page capture).
  async function captureCanvas(args = {}) {
    await ensureHtml2Canvas();
    const { el, clipped } = resolveCaptureTarget(args);
    const patches = patchStylesheetsForCapture();
    try {
      const canvas = await window.html2canvas(el, {
        useCORS: true,
        allowTaint: true,
        logging: false,
        ignoreElements: (e) => e.id === "la-root",
      });
      let rect = null;
      if (clipped) {
        const r = el.getBoundingClientRect();
        rect = {
          x: Math.round(r.left),
          y: Math.round(r.top),
          width: Math.round(r.width),
          height: Math.round(r.height),
        };
      }
      return { canvas, rect, oklch_patches: patches.length };
    } finally {
      revertStylesheetPatches(patches);
    }
  }

  async function cmdScreenshot(args = {}) {
    const { canvas, rect, oklch_patches } = await captureCanvas(args);
    const dataUrl = canvas.toDataURL("image/png");
    const base64 = dataUrl.replace(/^data:image\/png;base64,/, "");
    recordScreenshot({
      dataUrl,
      width: canvas.width,
      height: canvas.height,
      selector: args.selector || (args.cid != null ? "[cid=" + args.cid + "]" : null),
    });
    return {
      ok: true,
      base64,
      width: canvas.width,
      height: canvas.height,
      rect,
      oklch_patches,
    };
  }

  // ─── Visual diff (pixelmatch) ───────────────────────────────────────────────
  //
  // pixelmatch is the diff engine — a tiny, zero-dependency lib with built-in
  // anti-aliasing detection, so sub-pixel render noise doesn't inflate the
  // changed ratio. Vendored inline (verbatim from pixelmatch@5.3.0, ISC
  // license, https://github.com/mapbox/pixelmatch) so the diff works offline
  // with no CDN fetch at diff time. The only adaptation is dropping the
  // CommonJS `module.exports` wrapper.

  const pixelmatchDefaults = {
    threshold: 0.1,
    includeAA: false,
    alpha: 0.1,
    aaColor: [255, 255, 0],
    diffColor: [255, 0, 0],
    diffColorAlt: null,
    diffMask: false,
  };

  function pixelmatch(img1, img2, output, width, height, options) {
    if (!pmIsPixelData(img1) || !pmIsPixelData(img2) || (output && !pmIsPixelData(output)))
      throw new Error("Image data: Uint8Array, Uint8ClampedArray or Buffer expected.");

    if (img1.length !== img2.length || (output && output.length !== img1.length))
      throw new Error("Image sizes do not match.");

    if (img1.length !== width * height * 4)
      throw new Error("Image data size does not match width/height.");

    options = Object.assign({}, pixelmatchDefaults, options);

    const len = width * height;
    const a32 = new Uint32Array(img1.buffer, img1.byteOffset, len);
    const b32 = new Uint32Array(img2.buffer, img2.byteOffset, len);
    let identical = true;

    for (let i = 0; i < len; i++) {
      if (a32[i] !== b32[i]) {
        identical = false;
        break;
      }
    }
    if (identical) {
      if (output && !options.diffMask) {
        for (let i = 0; i < len; i++) pmDrawGrayPixel(img1, 4 * i, options.alpha, output);
      }
      return 0;
    }

    const maxDelta = 35215 * options.threshold * options.threshold;
    let diff = 0;

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const pos = (y * width + x) * 4;
        const delta = pmColorDelta(img1, img2, pos, pos);

        if (Math.abs(delta) > maxDelta) {
          if (!options.includeAA && (pmAntialiased(img1, x, y, width, height, img2) ||
                                     pmAntialiased(img2, x, y, width, height, img1))) {
            if (output && !options.diffMask) pmDrawPixel(output, pos, ...options.aaColor);
          } else {
            if (output) {
              pmDrawPixel(output, pos, ...((delta < 0 && options.diffColorAlt) || options.diffColor));
            }
            diff++;
          }
        } else if (output) {
          if (!options.diffMask) pmDrawGrayPixel(img1, pos, options.alpha, output);
        }
      }
    }

    return diff;
  }

  function pmIsPixelData(arr) {
    return ArrayBuffer.isView(arr) && arr.constructor.BYTES_PER_ELEMENT === 1;
  }

  function pmAntialiased(img, x1, y1, width, height, img2) {
    const x0 = Math.max(x1 - 1, 0);
    const y0 = Math.max(y1 - 1, 0);
    const x2 = Math.min(x1 + 1, width - 1);
    const y2 = Math.min(y1 + 1, height - 1);
    const pos = (y1 * width + x1) * 4;
    let zeroes = x1 === x0 || x1 === x2 || y1 === y0 || y1 === y2 ? 1 : 0;
    let min = 0;
    let max = 0;
    let minX, minY, maxX, maxY;

    for (let x = x0; x <= x2; x++) {
      for (let y = y0; y <= y2; y++) {
        if (x === x1 && y === y1) continue;

        const delta = pmColorDelta(img, img, pos, (y * width + x) * 4, true);

        if (delta === 0) {
          zeroes++;
          if (zeroes > 2) return false;
        } else if (delta < min) {
          min = delta;
          minX = x;
          minY = y;
        } else if (delta > max) {
          max = delta;
          maxX = x;
          maxY = y;
        }
      }
    }

    if (min === 0 || max === 0) return false;

    return (pmHasManySiblings(img, minX, minY, width, height) && pmHasManySiblings(img2, minX, minY, width, height)) ||
           (pmHasManySiblings(img, maxX, maxY, width, height) && pmHasManySiblings(img2, maxX, maxY, width, height));
  }

  function pmHasManySiblings(img, x1, y1, width, height) {
    const x0 = Math.max(x1 - 1, 0);
    const y0 = Math.max(y1 - 1, 0);
    const x2 = Math.min(x1 + 1, width - 1);
    const y2 = Math.min(y1 + 1, height - 1);
    const pos = (y1 * width + x1) * 4;
    let zeroes = x1 === x0 || x1 === x2 || y1 === y0 || y1 === y2 ? 1 : 0;

    for (let x = x0; x <= x2; x++) {
      for (let y = y0; y <= y2; y++) {
        if (x === x1 && y === y1) continue;

        const pos2 = (y * width + x) * 4;
        if (img[pos] === img[pos2] &&
            img[pos + 1] === img[pos2 + 1] &&
            img[pos + 2] === img[pos2 + 2] &&
            img[pos + 3] === img[pos2 + 3]) zeroes++;

        if (zeroes > 2) return true;
      }
    }

    return false;
  }

  function pmColorDelta(img1, img2, k, m, yOnly) {
    let r1 = img1[k + 0];
    let g1 = img1[k + 1];
    let b1 = img1[k + 2];
    let a1 = img1[k + 3];

    let r2 = img2[m + 0];
    let g2 = img2[m + 1];
    let b2 = img2[m + 2];
    let a2 = img2[m + 3];

    if (a1 === a2 && r1 === r2 && g1 === g2 && b1 === b2) return 0;

    if (a1 < 255) {
      a1 /= 255;
      r1 = pmBlend(r1, a1);
      g1 = pmBlend(g1, a1);
      b1 = pmBlend(b1, a1);
    }

    if (a2 < 255) {
      a2 /= 255;
      r2 = pmBlend(r2, a2);
      g2 = pmBlend(g2, a2);
      b2 = pmBlend(b2, a2);
    }

    const y1 = pmRgb2y(r1, g1, b1);
    const y2 = pmRgb2y(r2, g2, b2);
    const y = y1 - y2;

    if (yOnly) return y;

    const i = pmRgb2i(r1, g1, b1) - pmRgb2i(r2, g2, b2);
    const q = pmRgb2q(r1, g1, b1) - pmRgb2q(r2, g2, b2);

    const delta = 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q;

    return y1 > y2 ? -delta : delta;
  }

  function pmRgb2y(r, g, b) { return r * 0.29889531 + g * 0.58662247 + b * 0.11448223; }
  function pmRgb2i(r, g, b) { return r * 0.59597799 - g * 0.27417610 - b * 0.32180189; }
  function pmRgb2q(r, g, b) { return r * 0.21147017 - g * 0.52261711 + b * 0.31114694; }

  function pmBlend(c, a) {
    return 255 + (c - 255) * a;
  }

  function pmDrawPixel(output, pos, r, g, b) {
    output[pos + 0] = r;
    output[pos + 1] = g;
    output[pos + 2] = b;
    output[pos + 3] = 255;
  }

  function pmDrawGrayPixel(img, i, alpha, output) {
    const r = img[i + 0];
    const g = img[i + 1];
    const b = img[i + 2];
    const val = pmBlend(pmRgb2y(r, g, b), (alpha * img[i + 3]) / 255);
    pmDrawPixel(output, i, val, val, val);
  }

  // Decodes a base64 PNG into ImageData via an offscreen canvas.
  function pngBase64ToImageData(base64) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const c = document.createElement("canvas");
        c.width = img.naturalWidth;
        c.height = img.naturalHeight;
        const ctx = c.getContext("2d");
        ctx.drawImage(img, 0, 0);
        resolve(ctx.getImageData(0, 0, c.width, c.height));
      };
      img.onerror = () => reject(new Error("failed to decode baseline PNG"));
      img.src = "data:image/png;base64," + base64;
    });
  }

  // Merges the changed (red-tinted) pixels of a pixelmatch diff buffer into a
  // small set of bounding boxes. Works on a coarse 16px occupancy grid and
  // connected-components over it — bounded regardless of image size.
  function mergeDiffBoxes(out, w, h) {
    const cell = 16;
    const cols = Math.ceil(w / cell);
    const rows = Math.ceil(h / cell);
    const occ = new Uint8Array(cols * rows);

    for (let y = 0; y < h; y++) {
      const rowBase = y * w;
      const gy = ((y / cell) | 0) * cols;
      for (let x = 0; x < w; x++) {
        const i = (rowBase + x) * 4;
        // pixelmatch paints counted-different pixels in the diff color (red);
        // anti-aliased / unchanged pixels are dimmed grey or yellow.
        if (out[i] > 200 && out[i + 1] < 100 && out[i + 2] < 100) {
          occ[gy + ((x / cell) | 0)] = 1;
        }
      }
    }

    const seen = new Uint8Array(cols * rows);
    const boxes = [];
    const stack = [];
    for (let start = 0; start < occ.length; start++) {
      if (!occ[start] || seen[start]) continue;
      let minC = cols, maxC = 0, minR = rows, maxR = 0;
      stack.push(start);
      seen[start] = 1;
      while (stack.length) {
        const idx = stack.pop();
        const c = idx % cols;
        const r = (idx / cols) | 0;
        if (c < minC) minC = c;
        if (c > maxC) maxC = c;
        if (r < minR) minR = r;
        if (r > maxR) maxR = r;
        const neighbors = [idx - 1, idx + 1, idx - cols, idx + cols];
        for (const n of neighbors) {
          if (n < 0 || n >= occ.length || seen[n] || !occ[n]) continue;
          // guard horizontal wrap-around at row edges
          if ((n === idx - 1 && c === 0) || (n === idx + 1 && c === cols - 1)) continue;
          seen[n] = 1;
          stack.push(n);
        }
      }
      boxes.push({
        x: minC * cell,
        y: minR * cell,
        w: Math.min((maxC - minC + 1) * cell, w - minC * cell),
        h: Math.min((maxR - minR + 1) * cell, h - minR * cell),
      });
    }

    // Cap the box count so a speckled diff doesn't return hundreds of regions.
    if (boxes.length > 40) {
      let x0 = w, y0 = h, x1 = 0, y1 = 0;
      for (const b of boxes) {
        x0 = Math.min(x0, b.x);
        y0 = Math.min(y0, b.y);
        x1 = Math.max(x1, b.x + b.w);
        y1 = Math.max(y1, b.y + b.h);
      }
      return [{ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }];
    }
    return boxes;
  }

  async function cmdScreenshotDiff(args = {}) {
    const baselineB64 = args.baseline_png;
    if (!baselineB64) throw new Error("screenshot_diff: missing baseline_png");

    const baseline = await pngBase64ToImageData(baselineB64);

    // Capture the current frame through the SAME path as the baseline.
    const { canvas } = await captureCanvas(args);
    const w = canvas.width;
    const h = canvas.height;

    if (baseline.width !== w || baseline.height !== h) {
      return {
        ok: true,
        dims_match: false,
        baseline_size: { width: baseline.width, height: baseline.height },
        current_size: { width: w, height: h },
      };
    }

    const ctx = canvas.getContext("2d");
    const current = ctx.getImageData(0, 0, w, h);
    const out = new ImageData(w, h);

    const changed = pixelmatch(baseline.data, current.data, out.data, w, h, {
      threshold: typeof args.threshold === "number" ? args.threshold : 0.1,
      includeAA: args.include_aa === true,
      diffColor: [255, 0, 0],
      alpha: 0.1,
    });

    const boxes = mergeDiffBoxes(out.data, w, h);

    const overlay = document.createElement("canvas");
    overlay.width = w;
    overlay.height = h;
    overlay.getContext("2d").putImageData(out, 0, 0);
    const diffB64 = overlay.toDataURL("image/png").replace(/^data:image\/png;base64,/, "");

    return {
      ok: true,
      dims_match: true,
      changed_ratio: changed / (w * h),
      changed_boxes: boxes,
      width: w,
      height: h,
      diff_png: diffB64,
    };
  }

  function recordScreenshot({ dataUrl, width, height, selector }) {
    const entry = {
      id: "shot-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8),
      ts: Date.now(),
      dataUrl,
      width,
      height,
      selector,
    };
    state.screenshots.unshift(entry);
    if (state.screenshots.length > SCREENSHOT_HISTORY_LIMIT) {
      state.screenshots.length = SCREENSHOT_HISTORY_LIMIT;
    }
    if (state.openPanes.includes("screenshots")) {
      renderPaneContent("screenshots");
    }
  }

  // ─── CSS injection ────────────────────────────────────────────────────────

  function cmdInjectCss({ id, css } = {}) {
    if (!css) throw new Error("inject_css requires 'css'");
    const styleId = "la-css-" + (id || "default");
    let el = document.getElementById(styleId);
    if (!el) {
      el = document.createElement("style");
      el.id = styleId;
      document.head.appendChild(el);
    }
    el.textContent = css;
    return { ok: true, style_id: styleId, length: css.length };
  }

  function cmdRevertCss({ id } = {}) {
    if (id) {
      const el = document.getElementById("la-css-" + id);
      if (el) el.remove();
      return { ok: true, removed: el ? 1 : 0 };
    }
    const all = [...document.querySelectorAll("[id^='la-css-']")];
    all.forEach((el) => el.remove());
    return { ok: true, removed: all.length };
  }

  // ─── Computed styles ──────────────────────────────────────────────────────

  function cmdGetComputedStyles({ selector, properties } = {}) {
    const target = selector ? document.querySelector(selector) : document.documentElement;
    if (!target) throw new Error("No element found for selector: " + selector);
    const computed = window.getComputedStyle(target);
    const r = target.getBoundingClientRect();
    const rect = { top: Math.round(r.top), left: Math.round(r.left), width: Math.round(r.width), height: Math.round(r.height) };

    let styles = {};
    if (properties && properties.length > 0) {
      for (const prop of properties) {
        styles[prop] = computed.getPropertyValue(prop);
      }
    } else {
      for (let i = 0; i < computed.length; i++) {
        styles[computed[i]] = computed.getPropertyValue(computed[i]);
      }
    }
    return { ok: true, selector: selector || null, rect, styles };
  }

  // ─── Scroll ───────────────────────────────────────────────────────────────

  function cmdScrollTo({ selector, behavior = "smooth" } = {}) {
    const target = selector ? document.querySelector(selector) : document.documentElement;
    if (!target) throw new Error("No element found for selector: " + selector);
    target.scrollIntoView({ behavior, block: "center" });
    const r = target.getBoundingClientRect();
    return { ok: true, selector: selector || null, rect: { top: Math.round(r.top), left: Math.round(r.left), width: Math.round(r.width), height: Math.round(r.height) } };
  }

  function runCommandOp(cmd) {
    const handler = commandOps[cmd.op];
    if (!handler) {
      return Promise.reject(new Error("not_implemented: " + cmd.op));
    }
    if (driveOps.has(cmd.op) && !state.driveEnabled) {
      return Promise.reject(
        new Error("drive_disabled — toggle 'Drive' in the LiveAgent panel to enable")
      );
    }
    return Promise.resolve().then(() => handler(cmd.args || {}));
  }

  function postCommandResult(id, body) {
    // `id` last so a result field named `id` can't clobber the correlation id.
    return fetch(BASE + "/api/commands/result", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...body, id }),
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
            <button class="la-launch-btn" data-pane="timeline">Timeline</button>
            <button class="la-launch-btn" data-pane="async">Async</button>
            <button class="la-launch-btn" data-pane="resources">Resources</button>
            <button class="la-launch-btn" data-pane="screenshots">Screenshots</button>
          </div>
          <div id="la-bar-right">
            <label id="la-drive-toggle" title="Allow Claude to click and navigate. Highlight works either way.">
              <input type="checkbox" id="la-drive-cb"${state.driveEnabled ? " checked" : ""}>
              <span>Drive</span>
            </label>
            ${standalone ? "" : `<label id="la-statusbar-toggle" title="Collapse the panel to a thin status bar — frees up vertical space in the host app. Click any panel button to expand again.">
              <input type="checkbox" id="la-statusbar-cb"${state.statusbarMode ? " checked" : ""}>
              <span>Statusbar</span>
            </label>`}
            <span id="la-cmd-pill" class="la-cmd-pill la-cmd-idle" title="Agent control: not connected"></span>
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

    const driveCb = document.getElementById("la-drive-cb");
    if (driveCb) {
      driveCb.addEventListener("change", () => {
        state.driveEnabled = driveCb.checked;
        try {
          localStorage.setItem("la-drive-enabled", driveCb.checked ? "1" : "0");
        } catch (_) {}
      });
    }

    const statusbarCb = document.getElementById("la-statusbar-cb");
    if (statusbarCb) {
      statusbarCb.addEventListener("change", () => setStatusbarMode(statusbarCb.checked));
    }

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
      startCommandLoop();
    } else if (state.openByDefault) {
      openPanel();
    }

    // Tell the server we're here, even if the panel itself isn't open yet —
    // command-handling tools (highlight, drive, screenshot) don't require
    // the panel to be visible, only that the JS bundle is loaded and the
    // page is hydrated. PanelStatus uses this to short-circuit the readiness
    // gate in CommandQueue. We re-fire on key transitions so a tab returning
    // from background or a LiveView page-transition refreshes the signal
    // promptly instead of waiting for the next 25s long-poll.
    postHello();
    window.addEventListener("pageshow", postHello);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") postHello();
    });
    window.addEventListener("phx:page-loading-stop", postHello);
  }

  // ─── Panel Controls ────────────────────────────────────────────────────────

  let tallMode = false;
  // Saved value of body's inline padding-bottom before we offset the page to
  // make room for the fixed panel. `null` means "not currently offset".
  let _savedBodyPaddingBottom = null;

  function panelExpandedHeightPx() {
    return tallMode ? 520 : 300;
  }

  function applyBodyOffset() {
    if (_savedBodyPaddingBottom === null) {
      _savedBodyPaddingBottom = document.body.style.paddingBottom || "";
    }
    const panel = document.getElementById("la-panel");
    const height = panel ? panel.offsetHeight : panelExpandedHeightPx();
    document.body.style.paddingBottom = height + "px";
  }

  function applyStatusbarMode() {
    const panel = document.getElementById("la-panel");
    const split = document.getElementById("la-split");
    if (!panel || !split) return;
    if (state.statusbarMode) {
      split.style.display = "none";
      // Match #la-bar height so only the toolbar shows. Setting height: auto
      // would also work but we want a stable known size for body padding math.
      panel.style.height = "36px";
    } else {
      split.style.display = "";
      panel.style.height = panelExpandedHeightPx() + "px";
    }
    applyBodyOffset();
  }

  function setStatusbarMode(enabled) {
    state.statusbarMode = !!enabled;
    const cb = document.getElementById("la-statusbar-cb");
    if (cb) cb.checked = state.statusbarMode;
    try {
      localStorage.setItem("la-statusbar-mode", state.statusbarMode ? "1" : "0");
    } catch (_) {}
    if (state.visible) applyStatusbarMode();
  }

  function clearBodyOffset() {
    if (_savedBodyPaddingBottom !== null) {
      document.body.style.paddingBottom = _savedBodyPaddingBottom;
      _savedBodyPaddingBottom = null;
    }
  }

  function openPanel() {
    state.visible = true;
    document.getElementById("la-panel").style.display = "flex";
    document.getElementById("la-toggle").style.display = "none";
    rebuildSplit();
    applyStatusbarMode();
    fetchLiveViews();
    state._pollTimer = setInterval(fetchLiveViews, 3000);
    startCommandLoop();
    try { localStorage.setItem("la-panel-open", "1"); } catch (_) {}
  }

  function closePanel() {
    state.visible = false;
    document.getElementById("la-panel").style.display = "none";
    document.getElementById("la-toggle").style.display = "";
    clearBodyOffset();
    clearInterval(state._pollTimer);
    clearInterval(state._eventsTimer);
    state._eventsTimer = null;
    stopCommandLoop();
    if (state.pickerActive) stopPicker();
    try { localStorage.setItem("la-panel-open", "0"); } catch (_) {}
  }

  function toggleHeight() {
    // Resize implies the user wants the panel expanded — exit statusbar mode
    // first so the toggle has something to act on.
    if (state.statusbarMode) setStatusbarMode(false);
    tallMode = !tallMode;
    const panel = document.getElementById("la-panel");
    panel.style.height = tallMode ? "520px" : "300px";
    applyBodyOffset();
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
      timeline: "Timeline",
      async: "Async",
      resources: "Resources",
      screenshots: "Screenshots",
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
    if (name === "timeline" && !state._timelineTimer) {
      fetchTimeline();
      state._timelineTimer = setInterval(fetchTimeline, 2000);
    }
    if (name === "async" && !state._asyncTimer) {
      fetchAsync();
      state._asyncTimer = setInterval(fetchAsync, 1000);
      state._asyncElapsedTimer = setInterval(tickAsyncElapsed, 500);
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
    if (name === "timeline" && !state.openPanes.includes("timeline")) {
      clearInterval(state._timelineTimer);
      state._timelineTimer = null;
    }
    if (name === "async" && !state.openPanes.includes("async")) {
      clearInterval(state._asyncTimer);
      state._asyncTimer = null;
      clearInterval(state._asyncElapsedTimer);
      state._asyncElapsedTimer = null;
    }
    rebuildSplit();
    updateLauncher();
  }

  function togglePane(name) {
    // Clicking a launcher button is a clear signal the user wants to see panes —
    // exit statusbar mode so there's somewhere for the pane to render.
    if (state.statusbarMode) setStatusbarMode(false);
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
    if (name === "timeline") el.innerHTML = renderTimeline();
    if (name === "async") el.innerHTML = renderAsync();
    if (name === "resources") el.innerHTML = renderResources();
    if (name === "screenshots") el.innerHTML = renderScreenshots();
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

    if (name === "timeline") {
      el.querySelectorAll(".la-tl-row").forEach((row) => {
        row.addEventListener("click", () => {
          const key = row.dataset.tlkey;
          const body = row.nextElementSibling;
          if (!body || !body.classList.contains("la-tl-body")) return;
          const open = body.style.display !== "none";
          body.style.display = open ? "none" : "block";
          state.expandedTimelineEntries[key] = !open;
          const arrow = row.querySelector(".la-tl-arrow");
          if (arrow) arrow.textContent = open ? "▶" : "▼";
        });
      });

      const hideToggle = el.querySelector("#la-tl-hide-unknown");
      if (hideToggle) {
        hideToggle.addEventListener("change", (e) => {
          state.hideUnknownTimeline = !!e.target.checked;
          try {
            localStorage.setItem(
              "la-hide-unknown-timeline",
              state.hideUnknownTimeline ? "1" : "0"
            );
          } catch (_) {}
          renderPaneContent("timeline");
        });
      }
    }

    if (name === "async") {
      el.querySelectorAll(".la-async-row").forEach((row) => {
        row.addEventListener("click", () => {
          const key = row.dataset.asynckey;
          const body = row.nextElementSibling;
          if (!body || !body.classList.contains("la-async-body")) return;
          const open = body.style.display !== "none";
          body.style.display = open ? "none" : "block";
          state.expandedAsyncEntries[key] = !open;
          const arrow = row.querySelector(".la-tl-arrow");
          if (arrow) arrow.textContent = open ? "▶" : "▼";
        });
      });
    }

    if (name === "screenshots") {
      el.querySelectorAll(".la-shot-open, .la-shot-thumb").forEach((node) => {
        node.addEventListener("click", () => openScreenshotInTab(node.dataset.shotId));
      });
      el.querySelectorAll(".la-shot-download").forEach((node) => {
        node.addEventListener("click", () => downloadScreenshot(node.dataset.shotId));
      });
      const clear = el.querySelector("#la-shots-clear");
      if (clear) {
        clear.addEventListener("click", () => {
          state.screenshots = [];
          renderPaneContent("screenshots");
        });
      }
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
            ${v.url ? `<a class="la-view-name la-view-link" href="${escHtml(v.url)}">${escHtml(shortName(v.view))}</a>` : `<span class="la-view-name">${escHtml(shortName(v.view))}</span>`}
            <span class="la-badge ${v.connected ? "la-green" : "la-gray"}">${v.connected ? "live" : "static"}</span>
            ${v.url ? `<a class="la-nav-btn" href="${escHtml(v.url)}" title="Navigate to ${escHtml(v.url)}">\u2192</a>` : ""}
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

    const comp = state.selectedComponent;
    const componentHtml = comp
      ? `<div class="la-section-label">Component</div>
        <div class="la-component-info">
          <span class="la-component-module">${escHtml(shortName(comp.module))}</span>
          ${comp.id ? `<span class="la-dim la-component-id">id: <code>${escHtml(comp.id)}</code></span>` : ""}
        </div>
        <div class="la-chips">
          ${(comp.assign_keys || []).map((k) => `<span class="la-chip">${escHtml(k)}</span>`).join("")}
        </div>`
      : el.phx && el.phx["data-phx-component"]
      ? `<div class="la-section-label">Component</div>
        <div class="la-dim" style="font-size:11px;padding:2px 0">Resolving\u2026</div>`
      : "";

    return `<div class="la-card">
      <div class="la-element-tag">${tag}</div>
      ${el.text ? `<div class="la-text-preview la-dim">${escHtml(el.text.slice(0, 120))}</div>` : ""}

      ${componentHtml}

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

  function renderScreenshots() {
    const shots = state.screenshots || [];
    const toolbar = `
      <div class="la-events-toolbar">
        <span class="la-dim">${shots.length} screenshot${shots.length !== 1 ? "s" : ""} (keeps last ${SCREENSHOT_HISTORY_LIMIT})</span>
        ${shots.length ? '<button id="la-shots-clear" class="la-btn la-btn-danger" style="padding:2px 8px;font-size:11px">Clear</button>' : ""}
      </div>`;

    if (!shots.length) {
      return toolbar + '<div class="la-dim" style="padding:12px">No screenshots yet. Captures from <code>take_screenshot</code> will appear here.</div>';
    }

    const tiles = shots
      .map((s) => {
        const when = new Date(s.ts).toLocaleTimeString();
        const sel = s.selector ? escHtml(s.selector) : "full viewport";
        return `
          <div class="la-shot-tile" data-shot-id="${s.id}">
            <img src="${s.dataUrl}" alt="screenshot at ${escHtml(when)}" class="la-shot-thumb" data-shot-id="${s.id}">
            <div class="la-shot-meta">
              <div class="la-shot-meta-row">
                <span class="la-shot-time">${escHtml(when)}</span>
                <span class="la-dim">${s.width}×${s.height}</span>
              </div>
              <div class="la-shot-meta-row la-dim" title="${escHtml(sel)}">${escHtml(sel)}</div>
              <div class="la-shot-actions">
                <button class="la-btn la-shot-open" data-shot-id="${s.id}">Open</button>
                <button class="la-btn la-shot-download" data-shot-id="${s.id}">Download</button>
              </div>
            </div>
          </div>`;
      })
      .join("");

    return toolbar + `<div class="la-shot-grid">${tiles}</div>`;
  }

  function openScreenshotInTab(id) {
    const shot = (state.screenshots || []).find((s) => s.id === id);
    if (!shot) return;
    // Convert the data URL to a Blob so it gets a stable about:blank-style URL
    // (most browsers refuse top-level navigation to data: URLs).
    const blob = dataUrlToBlob(shot.dataUrl);
    const url = URL.createObjectURL(blob);
    const win = window.open(url, "_blank", "noopener");
    // Revoke after the new tab has had a chance to load the resource.
    if (win) setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  function downloadScreenshot(id) {
    const shot = (state.screenshots || []).find((s) => s.id === id);
    if (!shot) return;
    const a = document.createElement("a");
    const stamp = new Date(shot.ts)
      .toISOString()
      .replace(/[-:]/g, "")
      .replace(/\..*/, "");
    a.href = shot.dataUrl;
    a.download = `live_agent_screenshot_${stamp}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  function dataUrlToBlob(dataUrl) {
    const [meta, b64] = dataUrl.split(",");
    const mime = (meta.match(/data:([^;]+)/) || [, "image/png"])[1];
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Blob([bytes], { type: mime });
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

  function renderTimeline() {
    const rawGroups = state.timeline || [];
    const hideUnknown = !!state.hideUnknownTimeline;

    const groups = rawGroups.map((g) => {
      const entries = (g.entries || []).filter(
        (e) => !hideUnknown || ((e.trigger && e.trigger.kind) || "unknown") !== "unknown"
      );
      return { ...g, entries };
    });

    const total = groups.reduce((n, g) => n + g.entries.length, 0);
    const rawTotal = rawGroups.reduce((n, g) => n + (g.entries ? g.entries.length : 0), 0);
    const hiddenCount = rawTotal - total;
    const hiddenNote =
      hideUnknown && hiddenCount > 0
        ? ` <span class="la-dim">(${hiddenCount} unknown hidden)</span>`
        : "";

    const toolbar = `
      <div class="la-events-toolbar">
        <span class="la-dim">${total} transition${total !== 1 ? "s" : ""} across ${groups.length} LiveView${groups.length !== 1 ? "s" : ""}${hiddenNote}</span>
        <label class="la-toolbar-toggle">
          <input type="checkbox" id="la-tl-hide-unknown" ${hideUnknown ? "checked" : ""}>
          Hide unknown (handle_info)
        </label>
      </div>`;

    if (total === 0) {
      const empty = hideUnknown && hiddenCount > 0
        ? `<div class="la-empty">All ${hiddenCount} transition${hiddenCount !== 1 ? "s" : ""} are unknown (handle_info) and hidden.<br><span class="la-dim">Uncheck the filter to see them.</span></div>`
        : '<div class="la-empty">No transitions captured yet.<br><span class="la-dim">Interact with the app — mounts, events, and handle_params will appear here with diffs.</span></div>';
      return toolbar + empty;
    }

    const groupsHtml = groups
      .filter((g) => g.entries.length)
      .map((g) => {
        const header = `<div class="la-tl-group-header">
          <span class="la-view-name">${escHtml(shortName(g.view))}</span>
          <span class="la-pid">${escHtml(g.pid)}</span>
        </div>`;

        const rows = g.entries
          .map((entry) => renderTimelineEntry(g.pid, entry))
          .join("");

        return `<div class="la-tl-group">${header}${rows}</div>`;
      })
      .join("");

    return toolbar + '<div class="la-tl-list">' + groupsHtml + "</div>";
  }

  function renderTimelineEntry(pid, entry) {
    const key = pid + ":" + entry.id;
    const expanded = !!state.expandedTimelineEntries[key];
    const kind = (entry.trigger && entry.trigger.kind) || "unknown";
    const isError = entry.result === "exception";
    const badgeCls = triggerBadgeClass(kind, isError);
    const label = triggerLabel(entry.trigger, isError);
    const dur = entry.duration_ms != null ? `<span class="la-event-time">${entry.duration_ms}ms</span>` : "";
    const time = timeAgo(entry.at);
    const counts = diffCounts(entry.diff);
    const countsHtml = counts
      ? `<span class="la-dim la-tl-counts">${counts}</span>`
      : "";

    const body = `<div class="la-tl-body" style="display:${expanded ? "block" : "none"}">
        ${entry.exception ? `<div class="la-event-error">${escHtml(entry.exception.kind)}: ${escHtml(entry.exception.reason)}</div>` : ""}
        <pre class="la-pre">${escHtml(JSON.stringify({trigger: entry.trigger, diff: entry.diff}, null, 2))}</pre>
      </div>`;

    return `<div class="la-tl-row la-event-row-clickable" data-tlkey="${escHtml(key)}">
      <span class="la-tl-arrow">${expanded ? "▼" : "▶"}</span>
      <span class="la-ev-badge ${badgeCls}">${escHtml(kind)}</span>
      <span class="la-event-label">${escHtml(label)}</span>
      ${countsHtml}
      <span class="la-event-right">${dur}<span class="la-event-time">${time}</span></span>
    </div>${body}`;
  }

  function triggerBadgeClass(kind, isError) {
    if (isError) return "la-ev-error";
    return (
      {
        mount: "la-ev-mount",
        handle_event: "la-ev-event",
        live_component_event: "la-ev-event",
        handle_params: "la-ev-params",
        unknown: "la-ev-unknown",
      }[kind] || "la-ev-info"
    );
  }

  function triggerLabel(trigger, isError) {
    if (!trigger) return "?";
    if (isError) return (trigger.event || trigger.kind || "") + " (crashed)";
    if (trigger.kind === "handle_event" || trigger.kind === "live_component_event") {
      return trigger.event || "(no event name)";
    }
    if (trigger.kind === "handle_params") return trigger.uri || "(handle_params)";
    if (trigger.kind === "mount") return "mount";
    if (trigger.kind === "unknown") return "handle_info (inferred)";
    return trigger.kind || "?";
  }

  function diffCounts(diff) {
    if (!diff) return "";
    if (diff.oversize) return "oversize";
    const c = diff.changed ? Object.keys(diff.changed).length : 0;
    const a = diff.added ? Object.keys(diff.added).length : 0;
    const r = diff.removed ? Object.keys(diff.removed).length : 0;
    const parts = [];
    if (c) parts.push(c + " changed");
    if (a) parts.push(a + " added");
    if (r) parts.push(r + " removed");
    return parts.join(", ");
  }

  function renderAsync() {
    const groups = state.async || [];

    const totals = groups.reduce(
      (acc, g) => {
        acc.pending += (g.pending || []).length;
        acc.history += (g.history || []).length;
        acc.results += (g.async_results || []).length;
        return acc;
      },
      { pending: 0, history: 0, results: 0 }
    );

    const toolbar = `
      <div class="la-events-toolbar">
        <span class="la-dim">${totals.pending} in flight · ${totals.history} completed · ${totals.results} AsyncResult assign${totals.results !== 1 ? "s" : ""}</span>
      </div>`;

    if (totals.pending + totals.history + totals.results === 0) {
      return (
        toolbar +
        '<div class="la-empty">No async activity.<br><span class="la-dim">Tasks launched via <code>start_async</code> / <code>assign_async</code> will appear here while they run, and stay in history after they complete.</span></div>'
      );
    }

    const visibleGroups = groups.filter(
      (g) =>
        (g.pending && g.pending.length) ||
        (g.history && g.history.length) ||
        (g.async_results && g.async_results.length)
    );

    const groupsHtml = visibleGroups.map(renderAsyncGroup).join("");
    return toolbar + '<div class="la-tl-list">' + groupsHtml + "</div>";
  }

  function renderAsyncGroup(g) {
    const header = `<div class="la-tl-group-header">
      <span class="la-view-name">${escHtml(shortName(g.view))}</span>
      <span class="la-pid">${escHtml(g.pid)}</span>
    </div>`;

    const pendingRows = (g.pending || []).map(renderAsyncPending).join("");

    const resultRows = (g.async_results || []).map(renderAsyncResult).join("");

    const historyRows = (g.history || [])
      .map((entry) => renderAsyncHistory(g.pid, entry))
      .join("");

    const sectionWrap = (label, body) =>
      body
        ? `<div class="la-async-section"><div class="la-section-label">${label}</div>${body}</div>`
        : "";

    return `<div class="la-tl-group">
      ${header}
      ${sectionWrap("In flight", pendingRows)}
      ${sectionWrap("AsyncResult assigns", resultRows)}
      ${sectionWrap("History", historyRows)}
    </div>`;
  }

  function renderAsyncPending(p) {
    const started = p.started_at ? Date.parse(p.started_at) : null;
    return `<div class="la-async-pending">
      <span class="la-ev-badge la-ev-pending">${escHtml(p.kind)}</span>
      <span class="la-event-name">${escHtml(p.name)}</span>
      <span class="la-dim">${escHtml(p.task_pid || "")}</span>
      <span class="la-event-right">
        <span class="la-event-time" data-async-started="${started || ""}">${started ? formatElapsed(Date.now() - started) : "—"}</span>
      </span>
    </div>`;
  }

  function renderAsyncResult(r) {
    const status = r.ok
      ? "ok"
      : r.failed != null
      ? "failed"
      : r.loading
      ? "loading"
      : "idle";
    const badge = {
      ok: "la-ev-mount",
      failed: "la-ev-error",
      loading: "la-ev-pending",
      idle: "la-ev-info",
    }[status];

    return `<div class="la-async-pending">
      <span class="la-ev-badge ${badge}">${escHtml(status)}</span>
      <span class="la-event-name">${escHtml(r.assign_key)}</span>
      <span class="la-dim">${r.failed != null ? escHtml(String(r.failed)) : ""}</span>
    </div>`;
  }

  function renderAsyncHistory(pid, entry) {
    const key = pid + ":" + entry.id;
    const expanded = !!state.expandedAsyncEntries[key];
    const isError = entry.result === "exit";
    const badge = isError ? "la-ev-error" : "la-ev-mount";
    const dur = entry.duration_ms != null ? `<span class="la-event-time">${entry.duration_ms}ms</span>` : "";
    const time = timeAgo(entry.at);
    const cross = entry.state_timeline_id
      ? `<span class="la-dim">→ timeline #${entry.state_timeline_id}</span>`
      : "";

    const body = `<div class="la-async-body" style="display:${expanded ? "block" : "none"}">
      ${isError ? `<div class="la-event-error">exit: ${escHtml(entry.exit_reason || "")}</div>` : ""}
      <pre class="la-pre">${escHtml(JSON.stringify(entry, null, 2))}</pre>
    </div>`;

    return `<div class="la-async-row la-event-row-clickable" data-asynckey="${escHtml(key)}">
      <span class="la-tl-arrow">${expanded ? "▼" : "▶"}</span>
      <span class="la-ev-badge ${badge}">${escHtml(entry.kind)}</span>
      <span class="la-event-name">${escHtml(entry.name)}</span>
      ${cross}
      <span class="la-event-right">${dur}<span class="la-event-time">${time}</span></span>
    </div>${body}`;
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

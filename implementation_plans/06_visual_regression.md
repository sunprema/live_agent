# Visual Regression — "Show Me What Changed On Screen"

> Requested by the PostOpGuard team, from a 75-session transcript audit (2026-05-25).
> `take_screenshot` is the most-called tool in the project's history (**156 calls**), and
> **31 sessions took ≥4 screenshots** — almost always the same loop: screenshot → eyeball →
> tweak (`inject_css`, 21×) → screenshot again. There is no *comparison* primitive, so every
> iteration re-sends a full-page image for Claude to diff by eye. That is the design-system
> workflow's biggest token + attention tax.

## Goal

Turn the screenshot tool from "capture a picture" into "tell me what moved." Two
user-facing scenarios:

1. **"Did my CSS change only what I intended?"** — snapshot a baseline, apply the change,
   ask for a diff → get back the changed regions + a percentage + an overlay image, instead
   of two full-page PNGs Claude must compare pixel-by-pixel in its head.
2. **"Just this card, please."** — capture *only* a component (by selector or `cid`) so the
   relevant 400×200 region isn't buried in a 1440×3000 full-page shot.

## Constraint (decided)

- **Diffing happens in the browser, not Elixir.** The panel already owns a canvas capture
  that handles DaisyUI/Tailwind-v4 `oklch()` palettes (commit `c459eda`). Comparing two
  `ImageData` buffers there reuses that pipeline and avoids adding a native image
  dependency (no `:mogrify`/`vix`, no shelling to `ffmpeg`) to a dev tool.
- **`pixelmatch` is the diff engine, not a hand-rolled pixel walk.** It is a tiny,
  zero-dependency JS library built for exactly this — two `ImageData` buffers in, a diff
  buffer + changed-pixel count out, with built-in anti-aliasing detection (which directly
  retires this plan's AA-noise risk). We bundle it into the panel JS. Our own code only
  does what `pixelmatch` doesn't: merge its per-pixel diff into changed bounding boxes.
- **Baselines are named and disk-backed**, alongside the existing `screenshots/` output, so
  they survive across MCP calls and the panel's reconnects.

## Mechanism (grounded in current code)

- `take_screenshot/1` (tools.ex) already dispatches a browser command and the panel
  renders to a canvas, oklch-safe. Element clipping = resolve a target's bounding rect
  (the `cid`→`[data-phx-component]` / selector resolution already used by
  `click`/`highlight_element`) and `drawImage` only that sub-rect.
- A diff = capture current `ImageData`, load the baseline PNG into a second canvas, run
  `pixelmatch(baseline, current, out, w, h, opts)` to get the changed-pixel count and a
  diff buffer, derive a changed-pixel ratio + merged bounding boxes from that buffer, and
  save `out` (the diff image, changed pixels tinted) next to the baseline.

## Architecture

```
Claude ──MCP──▶ screenshot_baseline(name, selector?)
                    │  panel captures (oklch-safe canvas), optional clip to rect
                    └─ store PNG → screenshots/baselines/<name>.png  (BaselineStore)

Claude ──MCP──▶ screenshot_diff(name, selector?)
                    │  panel captures current frame (same clip)
                    │  load baselines/<name>.png into a 2nd canvas
                    │  pixelmatch(baseline, current, out) → changed-px count + diff buffer
                    │  merge diff buffer → boxes[]; ratio = count / (w*h); dims_match?
                    │  save diff buffer (changed px tinted) → screenshots/diffs/<name>.png
                    └─ return summary + overlay path to Claude
```

**`screenshot_diff` return shape:**

```elixir
%{
  changed_ratio: 0.037,                 # fraction of pixels that differ
  changed_boxes: [%{x: 12, y: 480, w: 220, h: 64}, ...],  # merged dirty regions
  dims_match?: true,                    # false → layout reflowed (size changed)
  overlay_path: "screenshots/diffs/cart.png",
  baseline_path: "screenshots/baselines/cart.png"
}
```

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Element-clipped capture
- [x] Extend `take_screenshot` args with optional `selector` | `cid` | `text`: resolve the
      target (reuse `resolveTarget`, the resolver behind `click`/`highlight_element`) and
      capture just that element. Full-page stays the default when none is given. Capture is
      now a single shared `captureCanvas` path used by all three screenshot tools.
- [x] Return the captured `rect` in the result so Claude knows what region it got.

### Slice 2 — Named baselines
- [x] `LiveAgent.BaselineStore` (thin disk store under `screenshots/baselines/`, no
      GenServer), keyed by name; `put/2`, `get/1`, `list/0`, `put_diff/2`, plus
      `validate_name/1` (rejects traversal / unsafe chars).
- [x] MCP tool `screenshot_baseline(name, selector?/cid?/text?)` — capture (Slice 1 clip
      honored) and store. Overwrites on same name (documented).

### Slice 3 — Diff
- [x] Vendor `pixelmatch@5.3.0` inline into the panel JS (verbatim, ISC; CommonJS wrapper
      dropped, helpers namespaced `pm*`) — zero-dependency, AA-aware, works offline.
      Verified functionally identical to upstream across 200 randomized cases.
- [x] Panel JS (`cmdScreenshotDiff`): decode baseline PNG → ImageData, capture current via
      the shared `captureCanvas`, early-out with `dims_match: false` (+ both sizes) when
      dimensions differ, otherwise run
      `pixelmatch(baseline.data, current.data, out.data, w, h, {threshold, includeAA, diffColor:[255,0,0]})`.
- [x] From `pixelmatch`'s diff buffer (`out`): `changed_ratio = changed / (w*h)` and merge
      changed (red) pixels into bounding boxes via a coarse 16px occupancy grid +
      connected-components (capped at 40 → overall bbox).
- [x] Save the diff buffer (pixelmatch tints changed pixels red over a dimmed baseline) to
      `screenshots/diffs/<name>.png`.
- [x] MCP tool `screenshot_diff(name, selector?/cid?/text?)` returns the shape above;
      missing baseline → clear error pointing at `screenshot_baseline`.
- [x] Expose `pixelmatch`'s `threshold` (0–1 colour distance) and `include_aa` as optional
      args; defaults documented (threshold 0.1, anti-aliasing ignored by default).

### Slice 4 — Docs
- [x] README "Via visual regression" section: baseline → change → diff loop, the overlay
      output, the element-clip option, AA tuning, and the persistence location. MCP-tools
      table rows for `take_screenshot`, `screenshot_baseline`, `screenshot_diff`.

## Decisions deferred
- **Perceptual diffing (SSIM) — deferred to the CI tier, not the interactive loop.**
  `pixelmatch` (per-pixel + AA-aware, in-browser) is the right tool for "did my change touch
  only this card" on a deterministic same-machine render. True Structural Similarity Index
  earns its keep only when comparing *golden images* that may be rendered on different
  machines/headless browsers, where sub-perceptual render drift must be tolerated and a
  single robust score is the pass/fail. If/when that CI gate lands (next bullet), the
  recommended engine is **`evision` (`~> 0.1`)** — Elixir's native OpenCV NIF — running
  `Evision.quality_SSIM` server-side on the two PNGs. Deliberately **not** a default
  dependency: OpenCV is a heavyweight native artifact, and routing the browser-captured
  `ImageData` back through encode→server→decode reintroduces exactly the round-trip the
  browser-side constraint above exists to avoid. Add it only behind the CI gate, ideally as
  an optional dep so the interactive panel never pulls OpenCV.
- **Baseline versioning / git-tracked golden images** for CI — this plan is for the
  interactive dev loop, not a CI visual-regression gate. Park (this is where SSIM/`evision`
  above would live).
- **Cross-viewport baselines** (mobile vs desktop) — capture is whatever the panel browser
  currently is; multi-viewport is out of scope.

## Risks
- **Dimension mismatch** (page reflowed between baseline and diff): a pixel walk on
  differently-sized buffers is meaningless. Mitigation: detect first, return
  `dims_match?: false` with the two sizes instead of a bogus ratio.
- **Anti-aliasing / sub-pixel noise** inflating `changed_ratio`. Mitigation: `pixelmatch`'s
  built-in AA detection (`includeAA: false`, on by default) plus its `threshold`; document
  tuning. This is the main reason to use `pixelmatch` over a hand-rolled channel-delta walk.
- **Large full-page buffers**: a 1440×4000 RGBA diff is ~23MB in memory. Mitigation:
  encourage element-clipped diffs (Slice 1) in the tool description; cap full-page diff
  dimensions and warn past the cap.
- **oklch / capture parity**: the diff must use the *same* capture path as
  `take_screenshot` so palette handling matches. Mitigation: share the capture function;
  don't fork a second renderer.

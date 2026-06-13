# Phase F3 — Multi-instance (add/remove modules via right-click menu) Implementation Plan

> **For agentic workers:** Executed INLINE (executing-plans) in this session, TDD per task. Steps use `- [ ]` for tracking.

**Goal:** Let a user add and remove Module columns at runtime through a right-click context menu, with the strip and persisted layout staying consistent — and remove the fixed-count panics that block it.

**Architecture:** Two slices. **F3a** is a UX-independent, fully unit-tested foundation: a runtime instance-id allocator, pure `insert_column`/`remove_column` layout ops, an `apply_edit` that mutates the `modules` Vec and `layout` Vec in lockstep, and hardening of the two fixed-count panics (`reorder_modules`'s `.unwrap()`, the viewport-remap `.expect()`) — the latter extracted to a pure, tested `remap_to_layout_order`. **F3b** is the right-click menu: a modal `Menu` state in the render-side `Router`, pure menu geometry/hit-test helpers, and a host `Overlay` renderer (shared `FONT` `TextBrush` + a quad pipeline, drawn in a second `LoadOp::Load` pass) that draws the menu and the empty-strip hint. The Router's `handle()` returns a `Commit::{Reorder, Edit}`; the loop applies an `Edit` through F3a's `apply_edit`.

**Tech Stack:** Rust, `wgpu`, `wgpu_text` (JetBrains Mono), `baseview`, `nih-plug`. Crate package name is `nanometers` (`cargo test -p nanometers`).

**Design decisions (locked with the user, 2026-06-13):**
- Add/remove UX = **right-click context menu** (host popup; reusable later for per-module config).
- **Multiple instances of the same type allowed** (ids are a monotonic counter, not type-derived).
- **Flat menu**, no hover-expand submenu: `Add Waveform / Add Oscilloscope / Add Loudness`, plus `Remove` when the right-click was over a column.
- **Dismiss** by click-outside or selecting an item; **no Esc** (keyboard stays `Ignored` for DAW passthrough, ADR 0004).
- **Add inserts right after the right-clicked column.**
- **Empty strip allowed**, showing a faint `right-click to add a module` hint — doubles as the right-click teaching moment.

---

## Slice F3a — Foundation (no GPU, no UI; all unit-tested)

### Task 1: `next_instance_id` allocator (layout.rs)

**Files:** Modify `apps/nano-plugin/src/layout.rs` (+ test in its `mod tests`).

Runtime ids must be unique among *currently present* columns (router/reorder match by id). `max + 1` (or `0` when empty) needs no persisted counter and never collides with a live column. Reuse of a freed id is fine — ids aren't durable handles.

- [ ] **Step 1 (RED):** test `next_instance_id_is_one_past_the_max`:
  - `next_instance_id(&[]) == 0`
  - ids `{0, 1}` → `2`; ids `{5}` → `6`; ids `{2, 0, 9, 3}` → `10`.
- [ ] **Step 2:** run `cargo test -p nanometers next_instance_id` → FAIL (undefined).
- [ ] **Step 3 (GREEN):**
  ```rust
  /// The next free instance id for a runtime-added column: one past the current max (0 when empty).
  /// Ids need only be unique among present columns (router/reorder match by id), so reuse of a freed
  /// id is harmless — no persisted counter required.
  pub fn next_instance_id(cols: &[Column]) -> u64 {
      cols.iter().map(|c| c.instance_id).max().map_or(0, |m| m.saturating_add(1))
  }
  ```
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

### Task 2: `insert_column` / `remove_column` pure ops (layout.rs)

**Files:** Modify `apps/nano-plugin/src/layout.rs` (+ tests).

Insert lands a **flex** column right after `after`; intrinsic (fixed) sizing is reconciled later by the caller from the built module (layout.rs can't see module widths — same split as spawn). Returns the insertion index so the caller inserts the matching module at the same position. Remove is index-based, returns the removed id, no min-count guard (empty allowed).

- [ ] **Step 1 (RED):** tests:
  - `insert_column_lands_right_after_and_allocates_id`: from ids `[0,1]`, `insert_column(&mut v, 0, WAVEFORM)` returns `1` (index), `v[1].instance_id == 2`, `v[1].fixed_width_px.is_none()`, len 3, order ids `[0,2,1]`.
  - `insert_column_clamps_after_past_end`: `after = 99` inserts at the end.
  - `remove_column_drops_at_index_and_returns_id`: from ids `[0,1,2]`, `remove_column(&mut v, 1) == Some(1)`, ids `[0,2]`.
  - `remove_column_out_of_range_is_none`.
  - `remove_to_empty_is_allowed`: remove the last column → `v.is_empty()`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3 (GREEN):**
  ```rust
  /// Insert a fresh FLEX column of `module_type` right after index `after` (clamped). Allocates a new
  /// id. Returns the insertion index so the caller can insert the matching module at the same slot.
  /// Fixed (intrinsic) sizing is reconciled by the caller from the built module, as at spawn.
  pub fn insert_column(cols: &mut Vec<Column>, after: usize, module_type: &str) -> usize {
      let id = next_instance_id(cols);
      let at = (after + 1).min(cols.len());
      cols.insert(at, Column::new(id, module_type, 1.0));
      at
  }

  /// Remove the column at `index`, returning its instance_id; `None` if out of range. No minimum
  /// count — an empty strip is a valid state (it shows the right-click hint).
  pub fn remove_column(cols: &mut Vec<Column>, index: usize) -> Option<u64> {
      (index < cols.len()).then(|| cols.remove(index).instance_id)
  }
  ```
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

### Task 3: harden `reorder_modules` — total, no `.unwrap()` (input.rs)

**Files:** Modify `apps/nano-plugin/src/input.rs:63` (+ test).

Compute the permutation BEFORE draining; bail (leave `modules` untouched) if `new` isn't a clean permutation of `old` by id. Removes both `.unwrap()`s. Reorder always preserves the id set today, so this is a no-op behaviorally — it just can't panic if the invariant ever slips (e.g. a future edit path).

- [ ] **Step 1 (RED):** test in input.rs `mod tests` using `FakeMod` (a no-GPU `Module` impl returning `Ignored`):
  - `reorder_modules_permutes_by_id`: modules tagged via `save_config` bytes `[0],[1],[2]`; old ids `[0,1,2]`, new `[2,0,1]` → modules end up `[2],[0],[1]`.
  - `reorder_modules_bails_on_id_mismatch`: new contains an id not in old → `modules` unchanged (len + order intact).
- [ ] **Step 2:** run → FAIL (current code panics / wrong).
- [ ] **Step 3 (GREEN):**
  ```rust
  fn reorder_modules(modules: &mut Vec<Box<dyn Module + Send>>, old: &[Column], new: &[Column]) {
      if new.len() != old.len() { return; }
      // Resolve each new column to its module index; abort the whole permute if any id is unknown
      // (a clean permutation always resolves — this only guards a slipped invariant from panicking).
      let Some(order) = new
          .iter()
          .map(|c| old.iter().position(|o| o.instance_id == c.instance_id))
          .collect::<Option<Vec<usize>>>()
      else {
          return;
      };
      let mut slots: Vec<Option<Box<dyn Module + Send>>> = modules.drain(..).map(Some).collect();
      *modules = order.into_iter().filter_map(|oi| slots[oi].take()).collect();
  }
  ```
  Add a shared test helper `FakeMod { config: Vec<u8> }` in input.rs tests (mirrors editor.rs's `FakeModule`).
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

### Task 4: extract + test `remap_to_layout_order`, kill the viewport `.expect()` (editor.rs / layout.rs)

**Files:** Add pure fn to `apps/nano-plugin/src/layout.rs` (+ tests); rewrite `editor.rs:607-616` to call it.

The render loop maps each committed column to its slot in the active (provisional during a drag, else identity) order. Extract that to a pure fn and replace `.expect()` with `unwrap_or(i)` (identity fallback): `active`/`active_vps` are always the same length as `layout` (provisional is a permutation; identity otherwise), so `j` is always in bounds and the function can't panic.

- [ ] **Step 1 (RED):** tests:
  - `remap_identity_when_active_is_layout`: active == layout → returns `active_vps` unchanged.
  - `remap_follows_provisional_permutation`: layout ids `[0,1]`, active `[1,0]`, `active_vps = [A, B]` → result `[B, A]` (column 0 gets active slot 1's rect).
  - `remap_falls_back_to_identity_on_unknown_id`: active missing a layout id → that column keeps its own-index rect (no panic).
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3 (GREEN):**
  ```rust
  /// Map each column in `layout` order to its viewport from the `active` order's `active_vps`
  /// (matched by instance_id). `active` is the provisional reorder order during a drag, else `layout`
  /// itself (identity). All three are the same length, so the index fallback never goes out of bounds.
  pub fn remap_to_layout_order(layout: &[Column], active: &[Column], active_vps: &[Rect]) -> Vec<Rect> {
      layout
          .iter()
          .enumerate()
          .map(|(i, c)| {
              let j = active.iter().position(|a| a.instance_id == c.instance_id).unwrap_or(i);
              active_vps[j]
          })
          .collect()
  }
  ```
  In `editor.rs`, replace the `layout.iter().map(...).expect(...)` block with `remap_to_layout_order(&layout, active, &active_vps)`.
- [ ] **Step 4:** run `cargo test -p nanometers` → PASS. **Step 5:** commit.

### Task 5: `LayoutEdit` + `apply_edit` (editor.rs)

**Files:** Modify `apps/nano-plugin/src/editor.rs` (next to `build_module`/`load_configs`); test with the existing `FakeModule`.

The render-side seam that applies a menu intent, keeping `modules` and `layout` 1:1. Generic over a builder closure so tests pass a `FakeModule` factory and the real loop passes `build_module`. Insert reconciles fixed width from the built module (mirrors spawn); a new column's empty config loads as defaults.

- [ ] **Step 1 (RED):** tests with `FakeModule` (extend it with a `kind: String` so the factory can tag what it built, OR assert via len + ids):
  - `apply_edit_insert_adds_module_and_column_in_lockstep`: start 2 cols / 2 modules; `Insert { after: 0, module_type: WAVEFORM }` → 3 cols / 3 modules, new column at index 1 with a fresh id, `modules.len() == layout.len()`.
  - `apply_edit_remove_drops_both`: `Remove { index: 1 }` → 1 col / 1 module; the right one removed (check surviving id).
  - `apply_edit_remove_to_empty`: remove last → both empty.
  - `apply_edit_insert_pins_intrinsic_width`: a builder returning a module whose `intrinsic_width()` is `Some(150.0)` → the inserted column's `fixed_width_px == Some(150.0)`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3 (GREEN):**
  ```rust
  /// A runtime layout mutation from the context menu (ADR 0003 / 0004). The render loop applies it via
  /// [`apply_edit`], keeping `layout` and `modules` 1:1.
  pub enum LayoutEdit {
      /// Insert a new module of `module_type` right after the column at `after`.
      Insert { after: usize, module_type: String },
      /// Remove the column (and its module) at `index`.
      Remove { index: usize },
  }

  /// Apply a [`LayoutEdit`] to the live `layout` + `modules` together. `build` constructs the Module
  /// for an inserted column (real loop: `build_module`; tests: a FakeModule factory). An inserted
  /// column reconciles its fixed width from the built module (the module is the size-of-truth, as at
  /// spawn) and loads its (empty) config so it boots at defaults.
  fn apply_edit<F>(layout: &mut Vec<Column>, modules: &mut Vec<Box<dyn Module + Send>>, edit: &LayoutEdit, mut build: F)
  where
      F: FnMut(&str) -> Box<dyn Module + Send>,
  {
      match edit {
          LayoutEdit::Insert { after, module_type } => {
              let at = crate::layout::insert_column(layout, *after, module_type);
              let mut module = build(module_type);
              if let Some(w) = module.intrinsic_width() {
                  layout[at].fixed_width_px = Some(w);
              }
              module.load_config(&layout[at].config);
              modules.insert(at, module);
          }
          LayoutEdit::Remove { index } => {
              if crate::layout::remove_column(layout, *index).is_some() {
                  modules.remove(*index);
              }
          }
      }
  }
  ```
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

---

## Slice F3b — Right-click context menu (live-verified GPU + UX)

### Task 6: share `FONT` (module/mod.rs)

**Files:** Modify `apps/nano-plugin/src/module/mod.rs` (add `pub(crate) const FONT`) and `apps/nano-plugin/src/module/loudness.rs` (use `super::FONT`, drop its local const + `include_bytes!`).

Avoids embedding the ~200 KB TTF twice. Pure relocation — no DSP, no numerics.

- [ ] **Step 1:** add to `module/mod.rs`:
  ```rust
  /// Embedded OFL font (JetBrains Mono), shared by every Module/host overlay that renders text (ADR 0005).
  pub(crate) const FONT: &[u8] = include_bytes!("../../assets/fonts/JetBrainsMono-Regular.ttf");
  ```
- [ ] **Step 2:** in `loudness.rs` delete `const FONT` and use `super::FONT` in `BrushBuilder::using_font_bytes`.
- [ ] **Step 3:** `cargo test -p nanometers` → PASS (unchanged behavior). Commit.

### Task 7: pure menu model + geometry/hit-test (new `apps/nano-plugin/src/menu.rs`)

**Files:** Create `apps/nano-plugin/src/menu.rs`; `mod menu;` in `lib.rs`.

Everything here is pure and unit-tested; no GPU. The Overlay (Task 9) and Router (Task 8) consume it.

- [ ] **Step 1 (RED):** tests:
  - `items_over_a_column_include_remove`: `MenuModel::for_context(Some(2))` yields `[Add Waveform, Add Oscilloscope, Add Loudness, Remove]`; `for_context(None)` (empty strip) yields just the three Adds.
  - `menu_rect_clamps_to_surface`: an anchor near the right/bottom edge shifts the panel left/up so it stays fully on-surface.
  - `menu_item_at_maps_cursor_y_to_row`: cursor inside row 0's band → `Some(0)`; below the panel / outside its x-band → `None`.
  - `edit_for_selection`: selecting `Add Loudness` over column 2 → `LayoutEdit::Insert { after: 2, module_type: "loudness" }`; selecting `Remove` over column 2 → `LayoutEdit::Remove { index: 2 }`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3 (GREEN):** implement:
  - `enum MenuAction { Add(&'static str /*module_type*/), Remove }` and `MenuItem { label: String, action: MenuAction }`.
  - `struct MenuModel { items: Vec<MenuItem>, column: Option<usize> }` with `for_context(column: Option<usize>)`.
  - `to_edit(&self, item: usize) -> Option<LayoutEdit>` (Add → Insert{after: column.unwrap_or(len-ish)}, Remove → Remove{index: column}). For the empty-strip case (`column == None`), Add inserts at the end — encode `after` as a value that `insert_column` clamps (e.g. `usize::MAX`), or carry `Option`. Keep `after: usize` with `usize::MAX` sentinel relying on the clamp proven in Task 2.
  - Geometry consts in LOGICAL px (× scale at call sites): `ITEM_H`, `MENU_W`, `PAD`. `menu_rect(anchor_px, n_items, surface_w, surface_h, scale) -> Rect` (clamped). `menu_item_at(rect, n_items, cursor_px, scale) -> Option<usize>`.
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

### Task 8: Router modal Menu state + `Commit` return (input.rs)

**Files:** Modify `apps/nano-plugin/src/input.rs`; update its tests + `editor.rs` call site.

The Router gains `menu: Option<OpenMenu>` (the `MenuModel` + anchor + hovered row). `handle()` returns `Option<Commit>` where `enum Commit { Reorder(Vec<Column>), Edit(LayoutEdit) }`. When the menu is open it is **modal**: cursor-moves update the hovered row only; a Left press selects (→ `Commit::Edit`) or dismisses; nothing forwards to modules; no reorder starts.

- [ ] **Step 1 (RED):** pure-ish tests driving `handle` with synthetic events (scale 1.0):
  - `right_click_opens_menu_with_remove_over_a_column`: after a CursorMoved into column 1 + `ButtonPressed{Right}`, `router.menu_overlay().is_some()` and its model has a `Remove`.
  - `left_click_on_add_item_returns_edit_and_closes`: open menu, move onto the `Add Waveform` row, `ButtonPressed{Left}` → returns `Some(Commit::Edit(Insert{..}))` and menu closes.
  - `left_click_outside_dismisses_without_edit`: open menu, click far outside → returns `None`, menu closed.
  - `menu_open_suppresses_reorder`: with menu open, a Left press on a column body does NOT begin a `LayoutReorder`.
  - Existing reorder tests updated to the `Commit::Reorder` shape.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3 (GREEN):** add the `Right` press arm (open/reposition menu when `grab == None`), make `CursorMoved`/`Left` press/release check `self.menu` first (modal), thread `MenuModel::for_context(column_index_at(...))`, and add `pub fn menu_overlay(&self) -> Option<MenuOverlay<'_>>` for the renderer (anchor + items + hovered + surface size). Change `handle` signature to `-> Option<Commit>`; map the existing reorder-commit path to `Commit::Reorder`.
- [ ] **Step 4:** update `editor.rs` loop to `match` on `Commit` (apply `Reorder` as today; apply `Edit` via `apply_edit(.., |t| build_module(t, &device, fmt))`). `cargo test -p nanometers` → PASS. **Step 5:** commit.

### Task 9: host `Overlay` renderer — menu + empty hint (new `apps/nano-plugin/src/overlay.rs`)

**Files:** Create `apps/nano-plugin/src/overlay.rs`; construct it in `run_render_loop`; draw in a second pass. GPU — **verified live**, not unit-tested (no correct GPU seam; note in commit).

- [ ] **Step 1:** `struct Overlay { brush: Brush, quad_pipeline, quad_vbuf, brush_size }` built from `device, format` (mirror loudness's brush + bars pipeline; `pos: vec2` NDC + `color: vec3`, single-sample, matches the surface format). A tiny `OVERLAY_WGSL` (copy the bars shader shape).
- [ ] **Step 2:** `Overlay::render(&mut self, device, queue, encoder, view, surface_w, surface_h, scale, menu: Option<MenuOverlay>, strip_empty: bool)`:
  - If `menu.is_none() && !strip_empty` → return (no overlay pass).
  - `resize_view(surface_w, surface_h, queue)` if changed; build NDC quads (panel bg, hover-row highlight) into `quad_vbuf`; `brush.queue(...)` the item labels (or the centered hint when empty).
  - Open a `LoadOp::Load` pass on `view` (full surface, no per-column viewport/scissor); draw quads then `brush.draw(rpass)`.
- [ ] **Step 3:** in `run_render_loop`, after the module pass block closes, call `overlay.render(.., router.menu_overlay(), layout.is_empty())` (reuse the same `encoder`, before `queue.submit`).
- [ ] **Step 4:** `cargo build -p nanometers` clean; `cargo test -p nanometers` green. Commit.

### Task 10: live verification + docs

- [ ] **Step 1:** run the dev-player (`NANO_DEV_FILE=… cargo run --features dev-player --bin nanometers -- --backend dummy`); right-click → Add each type (lands after the clicked column); Remove down to empty (hint shows); add back; reorder still works; resize a two-flex result. Confirm no panics in the log.
- [ ] **Step 2:** `./build.sh` (from MAIN after merge — nested worktree builds main) and sanity-check in a NEW Logic project: add/remove persists across save/reopen (rides the same `set_layout` path as F1/F2).
- [ ] **Step 3:** docs — note multi-instance + the menu in `docs/adr/0003` and/or `0004` (the menu is the F-phase deferral those ADRs flagged); update `CONTEXT.md` if "context menu"/"overlay" want canonical entries. Commit.
- [ ] **Step 4:** run the `code-review` workflow over the branch diff; address findings; merge to main + push.

---

## Self-review notes
- **Sync invariant:** every edit path mutates `layout` and `modules` together (`apply_edit`), and viewports are always rebuilt from the post-edit `layout`; the two panics are removed, not just guarded. Menu edits only fire when `grab == None` (modal), so no edit lands mid-reorder — the dangling-id-mid-grab case the recon flagged is unreachable by construction.
- **Type consistency:** `LayoutEdit` defined in editor.rs (Task 5), referenced by `menu.rs` (Task 7) and `input.rs` (Task 8) — menu.rs/input.rs import it from the crate root. `Commit` defined in input.rs (Task 8). `FONT` shared in module/mod.rs (Task 6) before Overlay (Task 9) uses it.
- **No new persisted state:** ids derive from `max+1`; the layout Vec already persists via `EditorState`, so add/remove survive reopen through the existing `set_layout` → serde path (F1/F2) with zero new plumbing.

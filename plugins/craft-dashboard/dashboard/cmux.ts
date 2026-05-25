import { spawnSync } from "child_process";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";

const CMUX_PREFIX = "craft";

export interface FocusResult {
  ok: boolean;
  workspaceRef?: string;
  surfaceRef?: string;
  fallback?: boolean;
  error?: string;
}

function cmux(...args: string[]): { stdout: string; stderr: string; ok: boolean } {
  // cmux's IPC socket occasionally drops a request with
  //   "Error: Failed to write to socket"
  // right after another command modified GUI state (focus-window, move-
  // surface). The failures are transient — the next attempt 50–200ms later
  // succeeds. Retry the call a few times for those; non-socket failures
  // (e.g. "Pane not found") are surfaced immediately.
  // Backoffs: 50, 100, 200, 400, 800ms = ~1.5s total. Long enough to ride
  // out the daemon hiccups I've observed, short enough to not block the
  // HTTP request meaningfully.
  const BACKOFFS_MS = [50, 100, 200, 400, 800];
  let r: ReturnType<typeof spawnSync>;
  for (let attempt = 0; attempt <= BACKOFFS_MS.length; attempt++) {
    r = spawnSync("cmux", args, { encoding: "utf-8" });
    if (r.status === 0) break;
    const stderr = (r.stderr ?? "").toString();
    const isSocketBlip = /Failed to write to socket|broken pipe|Connection reset/i.test(stderr);
    if (!isSocketBlip || attempt === BACKOFFS_MS.length) break;
    sleepSyncMs(BACKOFFS_MS[attempt]);
  }
  // @ts-ignore — r is defined after the loop runs at least once.
  const ok = r!.status === 0;
  if (!ok || process.env.CRAFT_DASHBOARD_DEBUG === "1") {
    console.error(
      // @ts-ignore
      `[cmux] args=${JSON.stringify(args)} status=${r!.status} stdout=${(r!.stdout ?? "").slice(0, 200)} stderr=${(r!.stderr ?? "").slice(0, 200)}`,
    );
  }
  return {
    // @ts-ignore
    stdout: (r!.stdout ?? "").toString(),
    // @ts-ignore
    stderr: (r!.stderr ?? "").toString(),
    ok,
  };
}

function craftMux(projectDir: string, ...args: string[]): { stdout: string; stderr: string; ok: boolean } {
  const craftRoot = process.env.CRAFT_ROOT ?? join(import.meta.dir, "../../..");
  const bin = join(craftRoot, "bin", "craft-mux");
  const r = spawnSync(bin, args, { cwd: projectDir, encoding: "utf-8" });
  return {
    stdout: (r.stdout ?? "").toString(),
    stderr: (r.stderr ?? "").toString(),
    ok: r.status === 0,
  };
}

function sleepSyncMs(ms: number): void {
  // Real synchronous sleep via Atomics.wait — blocks the thread without
  // spinning the CPU. Bun's main thread can handle this fine for the short
  // backoffs we use (max 200ms).
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

interface CmuxTree {
  windows: Array<{
    ref: string;
    index: number;
    active?: boolean;
    current?: boolean;
    workspaces: Array<{
      ref: string;
      title: string;
      selected?: boolean;
      active?: boolean;
      panes: Array<{
        ref: string;
        focused?: boolean;
        surfaces: Array<{
          ref: string;
          title?: string;
          type?: string;
          url?: string | null;
          selected?: boolean;
          selected_in_pane?: boolean;
        }>;
      }>;
    }>;
  }>;
}

/**
 * `cmux focus-window` only accepts window UUIDs — passing `window:N` refs or
 * 0-based indexes returns "Invalid window id". The JSON tree gives us
 * `index` but not the UUID; `cmux list-windows` gives both. Build an
 * `index → UUID` map by parsing list-windows once per call.
 */
interface WindowInfo {
  uuid: string;
  index: number;
  selected: boolean;
}

function listWindows(): WindowInfo[] {
  const r = cmux("list-windows");
  const out: WindowInfo[] = [];
  if (!r.ok) return out;
  // Lines look like: "* 0: 56AF4C3A-... selected_workspace=... workspaces=22"
  //                  "  1: E27CAA2F-... selected_workspace=... workspaces=2"
  // The leading "*" marks the currently-selected window.
  for (const line of r.stdout.split("\n")) {
    const m = line.match(/^(\s*\*?\s*)(\d+):\s+([0-9A-Fa-f-]{36})\b/);
    if (!m) continue;
    out.push({
      uuid: m[3],
      index: Number(m[2]),
      selected: m[1].includes("*"),
    });
  }
  return out;
}

type LookupResult<T> =
  | { kind: "found"; value: T }
  | { kind: "missing"; titlesSeen: string[] }
  | { kind: "error"; error: string };

function loadTree(): { ok: true; tree: CmuxTree } | { ok: false; error: string } {
  const r = cmux("tree", "--all", "--json");
  if (!r.ok) return { ok: false, error: r.stderr.trim() || `cmux tree exited ${r.stderr || "non-zero"}` };
  try {
    return { ok: true, tree: JSON.parse(r.stdout) as CmuxTree };
  } catch (err) {
    return { ok: false, error: `failed to parse cmux tree JSON: ${String(err)}` };
  }
}

function findWorkspaceByTitle(title: string): LookupResult<{
  workspaceRef: string;
  windowRef: string;
  windowIndex: number;
}> {
  const loaded = loadTree();
  if (!loaded.ok) return { kind: "error", error: loaded.error };
  const titlesSeen: string[] = [];
  for (const w of loaded.tree.windows) {
    for (const ws of w.workspaces) {
      titlesSeen.push(ws.title);
      if (ws.title === title) {
        return {
          kind: "found",
          value: { workspaceRef: ws.ref, windowRef: w.ref, windowIndex: w.index },
        };
      }
    }
  }
  return { kind: "missing", titlesSeen };
}

function findSurfaceWindow(surfaceRef: string): { ref: string; index: number } | null {
  const loaded = loadTree();
  if (!loaded.ok) return null;
  for (const w of loaded.tree.windows) {
    for (const ws of w.workspaces) {
      for (const p of ws.panes) {
        for (const s of p.surfaces) {
          if (s.ref === surfaceRef) return { ref: w.ref, index: w.index };
        }
      }
    }
  }
  return null;
}

function focusWindowByIndex(index: number): void {
  const windows = listWindows();
  const target = windows.find(w => w.index === index);
  if (!target) return;
  // Always call focus-window. We used to skip when the target was marked
  // currently-selected to avoid a cmux IPC blip, but that marker reflects
  // GUI focus from the caller's process-tree perspective — not the human
  // operator's view. Skipping it meant clicking "focus terminal" from a
  // dashboard tab in a different window did nothing visible. The retry
  // logic in cmux() handles the IPC blip; correctness wins.
  cmux("focus-window", "--window", target.uuid);
}

function lookupStatus(workspaceRef: string, key: string): string | null {
  const r = cmux("list-status", "--workspace", workspaceRef);
  if (!r.ok) return null;
  for (const line of r.stdout.split("\n")) {
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    if (line.slice(0, eq) === key) return line.slice(eq + 1).trim();
  }
  return null;
}

/**
 * Bring a surface to the front: makes it the selected tab inside its pane,
 * focuses that pane, selects its workspace, AND brings its window to the
 * foreground. `cmux move-surface --focus true` covers everything except the
 * cross-window switch — without an explicit `focus-window`, clicking a task
 * in the dashboard "works" but the user's cmux UI stays on whichever window
 * they were viewing.
 *
 * `cmux focus-pane` is NOT the right tool here — it takes a pane ref, not a
 * surface ref, and even when given the right pane it doesn't switch which
 * tab is selected inside that pane.
 */
function focusSurface(surfaceRef: string): { ok: boolean; error?: string } {
  // Three operations are needed to actually "focus" a surface from a
  // dashboard tab that may live in a different workspace and/or window:
  //
  //   1. move-surface --focus true   — selects the surface within its pane
  //                                    AND focuses that pane.
  //   2. select-workspace            — switches the cmux UI to show this
  //                                    workspace.
  //   3. focus-window                — switches cmux windows when the
  //                                    workspace lives in a different
  //                                    window than where the user is.
  //
  // We extract the workspace/window from move-surface's own response
  // ("OK surface=... pane=... workspace=workspace:N window=window:M")
  // rather than a separate `tree --all --json` lookup. Saves one cmux
  // subprocess (~50-80ms) per focus action.
  const moved = cmux("move-surface", "--surface", surfaceRef, "--focus", "true");
  if (!moved.ok) {
    return { ok: false, error: moved.stderr.trim() };
  }
  const wsMatch = moved.stdout.match(/workspace=(\S+)/);
  const winMatch = moved.stdout.match(/window=(\S+)/);
  if (wsMatch) {
    cmux("select-workspace", "--workspace", wsMatch[1]);
  }
  if (winMatch) {
    const windowRef = winMatch[1];
    // window:1 → index 0, window:2 → index 1 in cmux's CLI conventions.
    const m = windowRef.match(/^window:(\d+)$/);
    if (m) focusWindowByIndex(Number(m[1]) - 1);
  }
  return { ok: true };
}

/**
 * Focus the agent surface for a specific task.
 *
 * The orchestrator's `spawn_task_pane` records `craft:pane:<task-id>=<surface-ref>`
 * as a workspace status entry on the per-task cmux workspace; we read it back
 * and bring that surface to the front. If the status entry is missing or the
 * recorded surface no longer exists (orchestrator was restarted, workspace
 * was reset, etc.), we fall back to selecting the workspace so the operator
 * at least lands in the right place.
 */
/**
 * Single tree --all --json call that answers everything we need to know
 * about the target task:
 *   • does the workspace exist?
 *   • is the recorded surface still alive?
 *   • is the surface already the active one (so we can short-circuit)?
 *   • what window/workspace/pane is it in?
 *
 * Collapses the previous lookup chain (tree + list-status + tree-again)
 * into one cmux subprocess for the common case where nothing has shifted.
 */
function resolveTaskState(
  projectName: string,
  taskId: string,
): {
  kind: "found";
  workspaceRef: string;
  windowIndex: number;
  surfaceRef: string | null;
  surfaceAlreadyActive: boolean;
  workspaceAlreadySelected: boolean;
} | { kind: "missing"; titlesSeen: string[] }
  | { kind: "error"; error: string } {
  const wsPrefix = `${CMUX_PREFIX}-${projectName}-${taskId}`;
  const loaded = loadTree();
  if (!loaded.ok) return { kind: "error", error: loaded.error };
  const titlesSeen: string[] = [];
  for (const w of loaded.tree.windows) {
    for (const ws of w.workspaces) {
      titlesSeen.push(ws.title);
      // Match exact OR with a `· human suffix` appended. Mirrors the
      // prefix-match behavior in bash's `_mux_ws_ref` so human-readable
      // workspace titles still resolve via the structured prefix key.
      const matches = ws.title === wsPrefix
        || ws.title.startsWith(wsPrefix + " ")
        || ws.title.startsWith(wsPrefix + "·");
      if (!matches) continue;
      // Find the agent surface by its tab title — `spawn_task_pane` renames
      // the tab to the task id via `cmux rename-tab --surface <s> "<task-id>"`.
      // We previously did `cmux list-status` to read a registered
      // `craft:pane:<task-id>` entry, but that call alone is ~490ms (most
      // of the focus latency), and the title-based lookup is free since
      // we're already iterating the tree.
      let surfaceRef: string | null = null;
      let surfaceAlreadyActive = false;
      for (const p of ws.panes) {
        for (const s of p.surfaces) {
          if (s.title === taskId) {
            surfaceRef = s.ref;
            surfaceAlreadyActive =
              !!s.selected && !!p.focused && !!ws.selected && !!w.active;
            break;
          }
        }
        if (surfaceRef) break;
      }
      return {
        kind: "found",
        workspaceRef: ws.ref,
        windowIndex: w.index,
        surfaceRef,
        surfaceAlreadyActive,
        workspaceAlreadySelected: !!ws.selected && !!w.active,
      };
    }
  }
  return { kind: "missing", titlesSeen };
}

export function focusTaskSurface(projectName: string, taskId: string): FocusResult {
  const state = resolveTaskState(projectName, taskId);
  if (state.kind === "error") {
    return { ok: false, error: `cmux: ${state.error} (try again — usually clears after a moment)` };
  }
  if (state.kind === "missing") {
    const craftTitles = state.titlesSeen.filter(t => t.startsWith(CMUX_PREFIX)).join(", ") || "(none)";
    return {
      ok: false,
      error: `no cmux workspace titled '${CMUX_PREFIX}-${projectName}-${taskId}' — saw: ${craftTitles}`,
    };
  }
  const { workspaceRef: ws, windowIndex, surfaceRef, surfaceAlreadyActive, workspaceAlreadySelected } = state;

  // Fast path: surface already selected, workspace selected, window current.
  // Skip the 5 action subprocesses entirely.
  if (surfaceRef && surfaceAlreadyActive) {
    return { ok: true, workspaceRef: ws, surfaceRef };
  }

  // No recorded surface (or it died). Fall back to just selecting the
  // workspace + focusing the window.
  if (!surfaceRef) {
    if (!workspaceAlreadySelected) cmux("select-workspace", "--workspace", ws);
    focusWindowByIndex(windowIndex);
    return {
      ok: true,
      workspaceRef: ws,
      fallback: true,
      error: "no surface registered for this task; focused the workspace as fallback",
    };
  }

  // Surface exists but isn't focused — do the full activation chain.
  const r = focusSurface(surfaceRef);
  if (!r.ok) {
    if (!workspaceAlreadySelected) cmux("select-workspace", "--workspace", ws);
    focusWindowByIndex(windowIndex);
    return {
      ok: true,
      workspaceRef: ws,
      surfaceRef,
      fallback: true,
      error: `move-surface failed (${r.error}); selected workspace as fallback`,
    };
  }
  return { ok: true, workspaceRef: ws, surfaceRef };
}

/**
 * Focus the diffhub browser surface for a task.
 *
 * `launch-diffhub` writes the cmux surface ref to
 * `tasks/<id>/<repo>/.orchestrator/diffhub.surface`. We don't know the repo
 * up front, so we scan the task dir for the first match.
 */
/**
 * Hand a URL off to the system default browser via macOS `open`. The cmux
 * in-app browser sometimes can't complete corporate SSO redirects, so links
 * to Linear / GitHub / yaml files are routed through this endpoint instead
 * of opening as cmux browser tabs.
 *
 * Allowlist: http(s) and file://. The dashboard only binds to 127.0.0.1, so
 * the practical attack surface is low, but we still refuse anything outside
 * those schemes to keep this from becoming an arbitrary-command vector.
 */
export function openExternal(rawUrl: string): { ok: boolean; opened?: string; error?: string } {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch (err) {
    return { ok: false, error: `invalid URL: ${String(err)}` };
  }
  if (!["http:", "https:", "file:"].includes(u.protocol)) {
    return { ok: false, error: `refused: only http/https/file allowed (got ${u.protocol})` };
  }
  const r = spawnSync("open", [rawUrl], { encoding: "utf-8" });
  if (r.status !== 0) {
    return {
      ok: false,
      error: r.stderr?.toString().trim() || `open exited ${r.status}`,
    };
  }
  return { ok: true, opened: rawUrl };
}

/**
 * Find and focus the cmux browser surface for a PR URL. We look for any
 * browser surface whose `url` starts with the canonical
 * `https://github.com/<org>/<repo>/pull/<n>` prefix — that way path
 * suffixes like `/files` or `#issuecomment-123` still match.
 *
 * Returns `ok: false` with a "not found" error if no such surface exists;
 * the caller (the /focus/pr/:id route) falls back to opening externally.
 */
export function focusPrSurface(prUrl: string): FocusResult {
  // Canonical PR base: scheme + host + /org/repo/pull/N
  const m = prUrl.match(/^(https?:\/\/[^/]+\/[^/]+\/[^/]+\/pull\/\d+)/);
  const prefix = m ? m[1] : prUrl;

  const loaded = loadTree();
  if (!loaded.ok) return { ok: false, error: loaded.error };

  for (const w of loaded.tree.windows) {
    for (const ws of w.workspaces) {
      for (const p of ws.panes) {
        for (const s of p.surfaces) {
          if (s.type !== "browser") continue;
          const url = s.url ?? "";
          if (!url.startsWith(prefix)) continue;
          const r = focusSurface(s.ref);
          if (!r.ok) {
            return {
              ok: false,
              surfaceRef: s.ref,
              error: r.error,
            };
          }
          return { ok: true, surfaceRef: s.ref };
        }
      }
    }
  }
  return { ok: false, error: `no cmux browser tab open for ${prefix}` };
}

export function focusDiffhubSurface(projectDir: string, taskId: string): FocusResult {
  const registered = craftMux(projectDir, "focus", taskId, "diffhub-review");
  if (registered.ok) {
    return { ok: true, surfaceRef: registered.stdout.trim() || undefined };
  }

  const taskDir = join(projectDir, "tasks", taskId);
  if (!existsSync(taskDir)) {
    return { ok: false, error: `no tasks/${taskId}/ directory` };
  }
  let sid: string | null = null;
  let repoDir: string | null = null;
  for (const sub of readdirSync(taskDir)) {
    const candidate = join(taskDir, sub, ".orchestrator", "diffhub.surface");
    if (existsSync(candidate)) {
      try {
        sid = readFileSync(candidate, "utf-8").trim();
        repoDir = sub;
        break;
      } catch {
        /* try next */
      }
    }
  }
  if (!sid) {
    return { ok: false, error: `no diffhub.surface in tasks/${taskId}/*/.orchestrator/` };
  }
  const r = focusSurface(sid);
  if (r.ok) return { ok: true, surfaceRef: sid };

  // Differentiate transient socket failures (caller should retry) from
  // genuine "surface not found" (likely stale .orchestrator/diffhub.surface
  // after a diffhub relaunch).
  const err = r.error ?? "";
  const isSocket = /Failed to write to socket|broken pipe|Connection reset/i.test(err);
  const isMissing = /not.?found|Pane not found|Surface not found|Invalid/i.test(err);
  const hint = isSocket
    ? "cmux IPC blip — try again in a moment"
    : isMissing
      ? `surface ${sid} no longer exists — diffhub may have been relaunched without updating ${repoDir}/.orchestrator/diffhub.surface`
      : "";
  return {
    ok: false,
    surfaceRef: sid,
    error: hint ? `${err} (${hint}; registry lookup also failed: ${registered.stderr.trim()})` : err,
  };
}

export function focusRegisteredSurface(projectDir: string, taskId: string, surfaceId: string): FocusResult {
  const r = craftMux(projectDir, "focus", taskId, surfaceId);
  if (!r.ok) {
    return { ok: false, error: r.stderr.trim() || `surface ${surfaceId} not found` };
  }
  return { ok: true, surfaceRef: r.stdout.trim() || undefined };
}

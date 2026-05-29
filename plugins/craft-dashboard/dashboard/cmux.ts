import { spawnSync } from "child_process";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";

export interface FocusResult {
  ok: boolean;
  workspaceRef?: string;
  surfaceRef?: string;
  fallback?: boolean;
  code?: string;
  error?: string;
}

export interface WorkspaceState {
  task_id?: string;
  exists?: boolean;
  attached?: boolean;
  detached?: boolean;
  workspace_ref?: string;
  surface_ref?: string;
  surface_exists?: boolean;
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

function loadTree(): { ok: true; tree: CmuxTree } | { ok: false; error: string } {
  const r = cmux("tree", "--all", "--json");
  if (!r.ok) return { ok: false, error: r.stderr.trim() || `cmux tree exited ${r.stderr || "non-zero"}` };
  try {
    return { ok: true, tree: JSON.parse(r.stdout) as CmuxTree };
  } catch (err) {
    return { ok: false, error: `failed to parse cmux tree JSON: ${String(err)}` };
  }
}

function cmuxUiUnavailable(error: string): FocusResult {
  return { ok: false, code: "cmux_ui_unavailable", error };
}

function isUiUnavailable(error: string): boolean {
  return /Failed to write to socket|broken pipe|Connection reset|failed to connect|connection refused|dial tcp|relay|socket|Swift|detached|unavailable|not attached/i.test(error);
}

/**
 * Bring a surface to the front inside its current workspace. Callers that know
 * the workspace/window should still select/focus them separately.
 *
 * `cmux focus-pane` is NOT the right tool here — it takes a pane ref, not a
 * surface ref, and even when given the right pane it doesn't switch which
 * tab is selected inside that pane.
 */
function focusSurface(surfaceRef: string): { ok: boolean; error?: string } {
  const focused = cmux("focus-surface", surfaceRef);
  if (!focused.ok) {
    return { ok: false, error: focused.stderr.trim() };
  }
  return { ok: true };
}

export function taskWorkspaceState(projectDir: string, taskId: string): WorkspaceState {
  const r = craftMux(projectDir, "workspace-state", taskId, "agent");
  if (!r.ok) return { task_id: taskId, error: r.stderr.trim() || r.stdout.trim() || "workspace state unavailable" };
  try {
    return JSON.parse(r.stdout) as WorkspaceState;
  } catch (err) {
    return { task_id: taskId, error: `failed to parse workspace state: ${String(err)}` };
  }
}

export function focusTaskSurface(projectDir: string, taskId: string, attach = false): FocusResult {
  const args = ["focus", taskId, "agent"];
  if (attach) args.push("--attach");
  const r = craftMux(projectDir, ...args);
  if (r.ok) return { ok: true, surfaceRef: r.stdout.trim() || undefined };
  const error = r.stderr.trim() || r.stdout.trim() || `failed to focus task ${taskId}`;
  return isUiUnavailable(error)
    ? cmuxUiUnavailable(error)
    : { ok: false, error };
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

/**
 * craft-dashboard — Lightweight web UI for the craft orchestrator.
 *
 * Reads the project's queue/ + frontmatter, renders a column-per-status
 * dashboard, and turns task titles into clickable links that focus the
 * matching cmux terminal/browser surface.
 *
 * Usage:
 *   bun server.tsx --project <path-to-craft-project> [--port 27434]
 *
 * Or via package.json:
 *   bun start --project /path/to/project
 *
 * Designed to be opened as a cmux browser surface inside the project
 * workspace so it sits alongside the orchestrator + agent terminals.
 */

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { parseArgs } from "node:util";
import chokidar from "chokidar";
import matter from "gray-matter";
import { Marked, Renderer } from "marked";
import { render } from "preact-render-to-string";
import { Dashboard } from "./views";
import { scanProject, type Task } from "./queue";
import { focusTaskSurface, focusDiffhubSurface, focusPrSurface, focusRegisteredSurface, openExternal } from "./cmux";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    project: { type: "string" },
    port: { type: "string", default: "27434" },
    host: { type: "string", default: "127.0.0.1" },
  },
  allowPositionals: false,
});

if (!values.project) {
  console.error("Usage: bun server.tsx --project <path-to-craft-project> [--port 27434] [--host 127.0.0.1]");
  process.exit(2);
}

const projectDir = values.project;
if (!existsSync(projectDir)) {
  console.error(`craft-dashboard: project dir does not exist: ${projectDir}`);
  process.exit(1);
}
const projectName = basename(projectDir);
const port = Number(values.port);
const host = values.host!;

// --- In-memory snapshot, refreshed by chokidar; pushed to SSE clients ---
let tasks: Task[] = scanProject(projectDir);
let snapshotTs = Date.now();

// SSE subscribers. Each connected dashboard browser tab adds a controller
// here; when chokidar fires we broadcast an `update` event so htmx's
// sse-trigger pulls fresh HTML without polling.
const sseClients = new Set<ReadableStreamDefaultController<Uint8Array>>();
const encoder = new TextEncoder();
const sseSend = (event: string, data: string) => {
  const payload = encoder.encode(`event: ${event}\ndata: ${data}\n\n`);
  for (const ctrl of sseClients) {
    try {
      ctrl.enqueue(payload);
    } catch {
      sseClients.delete(ctrl);
    }
  }
};

// Debounce: chokidar fires multiple events for one logical change (file
// open + write + close, atomic-rename, etc.). Coalesce to one rescan/push.
let refreshTimer: ReturnType<typeof setTimeout> | null = null;
const refresh = () => {
  if (refreshTimer) return;
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    try {
      tasks = scanProject(projectDir);
      snapshotTs = Date.now();
      sseSend("update", String(snapshotTs));
    } catch (err) {
      console.error("craft-dashboard: snapshot refresh failed:", err);
    }
  }, 100);
};

const watcher = chokidar.watch(
  [`${projectDir}/queue`, `${projectDir}/tasks`],
  { ignoreInitial: true, depth: 3, ignored: /\.git\// },
);
watcher.on("all", refresh);

// --- HTTP ---
function renderHtml(): string {
  const body = render(<Dashboard projectName={projectName} tasks={tasks} />);
  return `<!doctype html>\n${body}`;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Render the modal markup for /task/:id. Reads the file fresh (not from the
 * in-memory snapshot) so the body always reflects the latest disk state —
 * worth the extra fs read since modals are opened on demand, not on every
 * SSE refresh.
 *
 * Links in the rendered markdown are routed through the dashboard's /open
 * endpoint so http(s) / file:// URLs open in the system default browser
 * (avoids cmux's in-app browser, which doesn't always handle corporate SSO).
 */
function renderTaskModal(task: Task): string {
  let raw: string;
  try {
    raw = readFileSync(task.filePath, "utf-8");
  } catch (err) {
    return modalError(`cannot read ${task.filePath}: ${String(err)}`);
  }
  const { content, data } = matter(raw);
  const fm = data as Record<string, unknown>;

  // marked Renderer with link rewrite — every http(s)/file:// link in the
  // body becomes an hx-post=/open?url=... button so it pops in the system
  // browser instead of inside cmux.
  const renderer = new Renderer();
  const origLink = renderer.link.bind(renderer);
  renderer.link = (token) => {
    const href = String((token as { href: string }).href ?? "");
    const text = (token as { text: string }).text ?? href;
    const isExternal = /^(https?:|file:)/i.test(href);
    if (!isExternal) return origLink(token);
    return `<a href="${escapeAttr(href)}"`
      + ` hx-post="/open?url=${encodeURIComponent(href)}"`
      + ` hx-swap="none"`
      + ` data-toast="opening"`
      + ` data-toast-success="opened"`
      + ` onclick="event.preventDefault()"`
      + `>${text}</a>`;
  };

  const md = new Marked({ gfm: true, breaks: false });
  const bodyHtml = md.parse(content, { renderer }) as string;

  // Pull a few header bits to show above the body (status, branch, deps).
  const status = (fm.status as string) ?? task.queueDir;
  const branch = task.branch ?? "";
  const linear = task.linearTickets.map(t =>
    `<a class="linear-pill" href="https://linear.app/linktree/issue/${t}"`
    + ` hx-post="/open?url=${encodeURIComponent(`https://linear.app/linktree/issue/${t}`)}"`
    + ` hx-swap="none" onclick="event.preventDefault()"`
    + ` data-toast="opening ${t}" data-toast-success="opened ${t}">${t}</a>`).join(" ");
  const pr = task.pr
    ? `<a class="pr-pill" href="${escapeAttr(task.pr)}"`
      + ` hx-post="/focus/pr/${escapeAttr(task.id)}"`
      + ` hx-swap="none" onclick="event.preventDefault()"`
      + ` data-toast="focusing PR" data-toast-success="focused PR">PR ${prShort(task.pr)}</a>`
    : "";

  return `
<div class="modal-backdrop" onclick="if(event.target===this)document.getElementById('modal').innerHTML=''">
  <article class="modal-card" role="dialog" aria-modal="true">
    <header class="modal-header">
      <div class="modal-title">
        <code>${escapeHtml(task.id)}</code>
        <span class="badge" style="background:${statusBadgeColor(status)}">${escapeHtml(status)}</span>
        ${linear}
        ${pr}
      </div>
      <button type="button" class="modal-close"
        onclick="document.getElementById('modal').innerHTML=''"
        title="Close (Esc)">✕</button>
    </header>
    ${branch ? `<div class="modal-meta"><b>branch</b> <code>${escapeHtml(branch)}</code></div>` : ""}
    <div class="markdown-body">${bodyHtml}</div>
  </article>
</div>`;
}

function modalError(msg: string): string {
  return `
<div class="modal-backdrop" onclick="if(event.target===this)document.getElementById('modal').innerHTML=''">
  <article class="modal-card" role="dialog" aria-modal="true">
    <header class="modal-header">
      <div class="modal-title"><span class="badge" style="background:#dc2626">error</span></div>
      <button type="button" class="modal-close"
        onclick="document.getElementById('modal').innerHTML=''">✕</button>
    </header>
    <p style="padding:1rem">${escapeHtml(msg)}</p>
  </article>
</div>`;
}

function statusBadgeColor(s: string): string {
  return ({
    "in-progress": "#2563eb",
    "diffhub-review": "#7c3aed",
    "waiting": "#d97706",
    "approved": "#6b7280",
    "pending": "#0891b2",
    "blocked": "#dc2626",
    "done": "#16a34a",
  } as Record<string, string>)[s] ?? "#6b7280";
}

function prShort(u: string): string {
  const m = u.match(/\/pull\/(\d+)/);
  return m ? `#${m[1]}` : "↗";
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
}
function escapeAttr(s: string): string {
  return s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
}

/**
 * Move a pending task to approved/, updating the `status:` frontmatter
 * field in place. Mirrors `move_task` in bin/lib/queue.sh — the
 * orchestrator's next poll will then pick the task up.
 */
function approveTask(projectDir: string, taskId: string) {
  const src = join(projectDir, "queue", "pending", `${taskId}.md`);
  if (!existsSync(src)) {
    return { ok: false, error: `no pending task at queue/pending/${taskId}.md` };
  }
  let body: string;
  try {
    body = readFileSync(src, "utf-8");
  } catch (err) {
    return { ok: false, error: `cannot read ${src}: ${String(err)}` };
  }
  // Replace the first `status:` line inside frontmatter. Frontmatter is the
  // first --- ... --- block. We deliberately only rewrite the first match
  // so a `status:` mention later in the body (e.g. in a code block) is
  // never touched.
  const fmEnd = body.indexOf("\n---", body.indexOf("---") + 3);
  const head = fmEnd >= 0 ? body.slice(0, fmEnd) : body;
  const tail = fmEnd >= 0 ? body.slice(fmEnd) : "";
  const rewritten = head.replace(/^status:.*$/m, "status: approved") + tail;

  const dst = join(projectDir, "queue", "approved", `${taskId}.md`);
  try {
    writeFileSync(src, rewritten);
    renameSync(src, dst);
  } catch (err) {
    return { ok: false, error: `move failed: ${String(err)}` };
  }
  return { ok: true, from: src, to: dst };
}

function signalReadyForPr(projectDir: string, taskId: string) {
  const craftBin = process.env.CRAFT_ROOT ? join(process.env.CRAFT_ROOT, "bin", "craft") : "craft";
  const proc = Bun.spawnSync({
    cmd: [craftBin, "task", "signal", taskId, "ready_for_pr", "--reason", "dashboard ready for PR"],
    cwd: projectDir,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (proc.exitCode !== 0) {
    return {
      ok: false,
      error: new TextDecoder().decode(proc.stderr).trim() || `craft exited ${proc.exitCode}`,
    };
  }
  return { ok: true, event: "ready_for_pr" };
}

const server = Bun.serve({
  port,
  hostname: host,
  fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/" && req.method === "GET") {
      return new Response(renderHtml(), {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    if (url.pathname === "/healthz") {
      return new Response("ok", { headers: { "content-type": "text/plain" } });
    }

    if (url.pathname === "/snapshot.json") {
      return jsonResponse({ snapshotTs, taskCount: tasks.length });
    }

    if (url.pathname === "/events" && req.method === "GET") {
      // ReadableStream's cancel() receives the reason, not the controller —
      // so we capture both controller and heartbeat-interval in closure
      // variables that both callbacks can see.
      let ctrl: ReadableStreamDefaultController<Uint8Array> | null = null;
      let hb: ReturnType<typeof setInterval> | null = null;
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          ctrl = controller;
          sseClients.add(controller);
          // Initial event so the client knows the pipe is live and can
          // sync against the current snapshot timestamp.
          controller.enqueue(encoder.encode(`event: ready\ndata: ${snapshotTs}\n\n`));
          // Heartbeat (SSE comment) every 25s — browsers and intermediaries
          // can close idle streams; this keeps the pipe warm.
          hb = setInterval(() => {
            try {
              controller.enqueue(encoder.encode(`: heartbeat\n\n`));
            } catch {
              if (hb) clearInterval(hb);
              sseClients.delete(controller);
            }
          }, 25_000);
        },
        cancel() {
          if (ctrl) sseClients.delete(ctrl);
          if (hb) clearInterval(hb);
        },
      });
      return new Response(stream, {
        headers: {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          "connection": "keep-alive",
          "x-accel-buffering": "no",
        },
      });
    }

    if (url.pathname.startsWith("/focus/task/") && req.method === "POST") {
      const id = decodeURIComponent(url.pathname.slice("/focus/task/".length));
      const r = focusTaskSurface(projectName, id);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname.startsWith("/focus/diffhub/") && req.method === "POST") {
      const id = decodeURIComponent(url.pathname.slice("/focus/diffhub/".length));
      const r = focusDiffhubSurface(projectDir, id);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname.startsWith("/focus/pr/") && req.method === "POST") {
      const id = decodeURIComponent(url.pathname.slice("/focus/pr/".length));
      const task = tasks.find(t => t.id === id);
      if (!task) return jsonResponse({ ok: false, error: `task ${id} not in snapshot` }, 404);
      if (!task.pr) return jsonResponse({ ok: false, error: `task ${id} has no pr in frontmatter` }, 400);
      const registered = focusRegisteredSurface(projectDir, id, "github-pr");
      if (registered.ok) return jsonResponse(registered);
      const f = focusPrSurface(task.pr);
      if (f.ok) return jsonResponse(f);
      // No cmux browser tab open for this PR — fall back to system browser
      // so the click still does *something* useful for the operator.
      const o = openExternal(task.pr);
      return jsonResponse(
        {
          ok: o.ok,
          fallback: "system-browser",
          surfaceLookupError: f.error,
          ...(o.ok ? { opened: o.opened } : { error: o.error }),
        },
        o.ok ? 200 : 502,
      );
    }

    if (url.pathname.startsWith("/ready/") && req.method === "POST") {
      const id = decodeURIComponent(url.pathname.slice("/ready/".length));
      const r = signalReadyForPr(projectDir, id);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname === "/open" && req.method === "POST") {
      const target = url.searchParams.get("url");
      if (!target) return jsonResponse({ ok: false, error: "missing ?url" }, 400);
      const r = openExternal(target);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname.startsWith("/approve/") && req.method === "POST") {
      const id = decodeURIComponent(url.pathname.slice("/approve/".length));
      const r = approveTask(projectDir, id);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname.startsWith("/task/") && req.method === "GET") {
      const id = decodeURIComponent(url.pathname.slice("/task/".length));
      const task = tasks.find(t => t.id === id);
      if (!task) {
        return new Response(modalError(`task ${id} not found in snapshot`), {
          status: 404,
          headers: { "content-type": "text/html; charset=utf-8" },
        });
      }
      return new Response(renderTaskModal(task), {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(`craft-dashboard → http://${host}:${server.port} (project: ${projectName})`);

const shutdown = () => {
  watcher.close();
  server.stop();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

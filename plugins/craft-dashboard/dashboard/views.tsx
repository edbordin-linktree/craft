import type { Task } from "./queue";
import { QUEUE_ORDER } from "./queue";
import type { WorkspaceState } from "./cmux";

const LINEAR_ORG = process.env.LINEAR_ORG ?? "linktree";
const DONE_LIMIT = Number(process.env.DONE_LIMIT ?? "8");
const inlineClick = (script: string) => ({ onclick: script }) as Record<string, string>;

const statusColor: Record<string, string> = {
  "drafts": "#64748b",
  "in-progress": "#2563eb",
  "local-review": "#7c3aed",
  "waiting": "#d97706",
  "approved": "#6b7280",
  "pending": "#0891b2",
  "blocked": "#dc2626",
  "done": "#16a34a",
};

const STYLES = `
  body { padding: 1rem; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; background: #0b0d10; color: #e6e8eb; margin: 0; }
  header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 1rem; }
  h1 { margin: 0; font-size: 1.1rem; font-weight: 600; }
  h1 code { font-family: 'SF Mono', monospace; color: #93c5fd; font-size: 0.95rem; }
  .meta-line { font-size: 0.8rem; color: #7e858d; }
  .columns { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1rem; align-items: start; }
  .column h2 { font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: #7e858d; margin: 0 0 0.5rem 0; }
  .task { padding: 0.7rem 0.8rem; border: 1px solid #1f242a; border-radius: 8px; margin-bottom: 0.6rem; background: #11151a; }
  .task.waiting-team { opacity: 0.72; }
  .task.child { margin-left: 0.8rem; border-left-color: #334155; }
  .parent-group { border: 1px solid #1f242a; border-radius: 8px; margin-bottom: 0.7rem; background: #0d1117; overflow: hidden; }
  .parent-group > .task { border: 0; border-radius: 0; margin-bottom: 0; background: #11151a; }
  .parent-children { padding: 0.65rem 0.7rem 0.1rem 0.7rem; border-top: 1px solid #1f242a; }
  .task-header { display: flex; align-items: center; gap: 0.55rem; flex-wrap: wrap; }
  .task-id { font-family: 'SF Mono', monospace; font-weight: 600; }
  .task-id a { color: #93c5fd; text-decoration: none; cursor: pointer; }
  .task-id a:hover { text-decoration: underline; }
  .linear-pill { font-size: 0.7rem; font-weight: 500; padding: 0.05rem 0.4rem; border-radius: 4px; background: #1a2331; color: #93c5fd; text-decoration: none; border: 1px solid #1e3a5f; }
  .linear-pill:hover { background: #1f2d3f; }
  .pr-pill { font-size: 0.7rem; font-weight: 600; padding: 0.05rem 0.4rem; border-radius: 4px; background: #1a2614; color: #86efac; text-decoration: none; border: 1px solid #2d5219; }
  .pr-pill:hover { background: #1f3018; }
  .wait-pill { font-size: 0.7rem; font-weight: 600; padding: 0.05rem 0.4rem; border-radius: 4px; background: #2a2112; color: #fbbf24; border: 1px solid #4b3410; }
  .summary { margin: 0.5rem 0 0 0; font-size: 0.85rem; color: #b8bdc4; line-height: 1.4; display: -webkit-box; -webkit-box-orient: vertical; overflow: hidden; }
  .summary.lines-2 { -webkit-line-clamp: 2; }
  .summary.lines-1 { -webkit-line-clamp: 1; }
  .task.done { opacity: 0.65; }
  .task.done .summary { color: #97a0aa; }
  .actions { margin-top: 0.6rem; display: flex; gap: 0.35rem; flex-wrap: wrap; }
  .actions button, .actions a { padding: 0.22rem 0.6rem; font-size: 0.78rem; border: 1px solid #1f242a; border-radius: 5px; text-decoration: none; cursor: pointer; color: #c9ced4; background: #171b21; font-family: inherit; }
  .actions button:hover, .actions a:hover { background: #1f242a; }
  .actions .primary { color: #93c5fd; border-color: #1e3a5f; background: #0f1820; }
  .actions .ready { color: #fbbf24; border-color: #92400e; background: #1c1408; }
  .actions .ready:hover { background: #2a1f0c; }
  .actions .approve { color: #86efac; border-color: #14532d; background: #0b1f12; }
  .actions .approve:hover { background: #102b1a; }
  details.more { margin-top: 0.6rem; }
  details.more summary { font-size: 0.7rem; color: #7e858d; cursor: pointer; user-select: none; padding: 0.15rem 0; list-style: none; }
  details.more summary::-webkit-details-marker { display: none; }
  details.more summary::before { content: "▸ "; font-size: 0.7em; }
  details.more[open] summary::before { content: "▾ "; }
  details.more summary:hover { color: #c9ced4; }
  .deps { margin-top: 0.5rem; font-size: 0.78rem; color: #c9ced4; padding: 0.3rem 0.55rem; border-radius: 5px; border: 1px solid #1f242a; background: #11151a; }
  .deps.blocked { color: #fca5a5; border-color: #4c1d1d; background: #1f0f0f; }
  .deps.ready   { color: #86efac; border-color: #14532d; background: #0b1f12; }
  .deps code { font-family: 'SF Mono', monospace; }
  .deps .dep-met { opacity: 0.6; text-decoration: line-through; }
  .kv { font-size: 0.78rem; color: #7e858d; margin-top: 0.4rem; display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 0.65rem; }
  .kv b { color: #97a0aa; font-weight: 500; }
  .kv a { color: #93c5fd; text-decoration: none; }
  .kv a:hover { text-decoration: underline; }
  .work-log { margin-top: 0.45rem; font-size: 0.76rem; color: #97a0aa; font-style: italic; padding-left: 0.5rem; border-left: 2px solid #1f242a; }
  .badge { padding: 0.08rem 0.5rem; font-size: 0.7rem; border-radius: 999px; color: white; font-weight: 600; }
  .toast { position: fixed; top: 1rem; right: 1rem; padding: 0.55rem 0.8rem; border-radius: 6px; font-size: 0.82rem; background: #1e3a5f; color: #93c5fd; box-shadow: 0 4px 12px rgba(0,0,0,0.5); opacity: 0; transition: opacity 0.2s; z-index: 100; max-width: 64ch; font-family: 'SF Mono', monospace; pointer-events: none; }
  .toast.show { opacity: 1; }
  .toast.error { background: #4c1d1d; color: #fca5a5; pointer-events: auto; display: flex; gap: 0.6rem; align-items: flex-start; }
  .toast.error .body { user-select: text; cursor: text; white-space: pre-wrap; word-break: break-word; flex: 1; }
  .toast.error .close { user-select: none; cursor: pointer; color: #fca5a5; opacity: 0.5; font-weight: bold; line-height: 1; padding-left: 0.2rem; }
  .toast.error .close:hover { opacity: 1; }
  /* Modal overlay + card. #modal is always in the DOM; CSS hides when empty. */
  #modal:empty { display: none; }
  .modal-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.7); z-index: 200; display: flex; align-items: flex-start; justify-content: center; padding: 4vh 2vw; overflow: hidden; }
  /* The CARD is the scroll container — that lets position:sticky on the
     header actually pin to the card top instead of escaping to the
     backdrop top (which is what was making text appear above the card). */
  .modal-card { background: #11151a; border: 1px solid #1f242a; border-radius: 10px; box-shadow: 0 12px 40px rgba(0,0,0,0.6); width: 100%; max-width: 880px; max-height: 92vh; overflow-y: auto; overflow-x: hidden; color: #e6e8eb; font-size: 0.92rem; line-height: 1.55; }
  .modal-header { display: flex; align-items: center; justify-content: space-between; gap: 1rem; padding: 0.85rem 1.1rem; border-bottom: 1px solid #1f242a; position: sticky; top: 0; background: #11151a; border-radius: 10px 10px 0 0; z-index: 1; }
  .modal-title { display: flex; align-items: center; gap: 0.55rem; flex-wrap: wrap; font-size: 0.95rem; }
  .modal-title code { font-family: 'SF Mono', monospace; font-weight: 600; color: #93c5fd; font-size: 0.95rem; }
  .modal-close { background: transparent; border: 0; color: #97a0aa; font-size: 1.15rem; cursor: pointer; padding: 0.2rem 0.5rem; border-radius: 4px; }
  .modal-close:hover { background: #1f242a; color: #e6e8eb; }
  .modal-meta { padding: 0.45rem 1.1rem; font-size: 0.78rem; color: #97a0aa; border-bottom: 1px solid #1f242a; }
  .modal-meta b { color: #c9ced4; font-weight: 500; margin-right: 0.4rem; }
  .modal-meta code { font-family: 'SF Mono', monospace; color: #c9ced4; }
  .markdown-body { padding: 1rem 1.1rem 1.5rem 1.1rem; }
  .markdown-body h1, .markdown-body h2, .markdown-body h3 { margin: 1.4rem 0 0.5rem 0; color: #e6e8eb; }
  .markdown-body h1 { font-size: 1.3rem; }
  .markdown-body h2 { font-size: 1.1rem; padding-bottom: 0.3rem; border-bottom: 1px solid #1f242a; }
  .markdown-body h3 { font-size: 1rem; color: #c9ced4; }
  .markdown-body p, .markdown-body li { color: #c9ced4; }
  .markdown-body ul, .markdown-body ol { padding-left: 1.4rem; }
  .markdown-body li { margin: 0.2rem 0; }
  .markdown-body code { font-family: 'SF Mono', monospace; background: #1a1f25; padding: 0.08rem 0.32rem; border-radius: 3px; font-size: 0.86em; color: #f8a978; overflow-wrap: anywhere; word-break: break-word; }
  .markdown-body pre { background: #0b0d10; border: 1px solid #1f242a; padding: 0.75rem 0.9rem; border-radius: 6px; overflow-x: auto; }
  .markdown-body pre code { background: transparent; padding: 0; color: #c9ced4; font-size: 0.82rem; }
  .markdown-body a { color: #93c5fd; text-decoration: none; }
  .markdown-body a:hover { text-decoration: underline; }
  .markdown-body blockquote { border-left: 3px solid #1e3a5f; padding: 0.2rem 0.9rem; color: #97a0aa; margin: 0.8rem 0; background: #0f1820; border-radius: 0 4px 4px 0; }
  .markdown-body input[type="checkbox"] { margin-right: 0.4rem; accent-color: #2563eb; }
  .markdown-body table { border-collapse: collapse; margin: 0.8rem 0; }
  .markdown-body th, .markdown-body td { border: 1px solid #1f242a; padding: 0.3rem 0.6rem; font-size: 0.86rem; }
  .markdown-body th { background: #11151a; color: #c9ced4; font-weight: 600; }
  .markdown-body hr { border: 0; border-top: 1px solid #1f242a; margin: 1rem 0; }
`;

const HTMX_HEAD = `
<script src="https://unpkg.com/htmx.org@2.0.4" integrity="sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+" crossorigin="anonymous"></script>
<script src="https://unpkg.com/htmx-ext-sse@2.2.4/sse.js" crossorigin="anonymous"></script>
<script>
  // Toast feedback for action buttons. Reads JSON {ok, error?} from htmx
  // responses and surfaces success/failure to the operator. Without this, a
  // 502 just silently looks like nothing happened.
  document.addEventListener("htmx:afterRequest", (evt) => {
    const target = evt.detail.elt;
    if (!target.dataset.toast) return;
    let body = {};
    try { body = JSON.parse(evt.detail.xhr.responseText); } catch {}
    const ok = evt.detail.xhr.status >= 200 && evt.detail.xhr.status < 300;
    const msg = ok
      ? (target.dataset.toastSuccess || target.dataset.toast + " ok")
      : (body.error || (evt.detail.xhr.status === 0
        ? "Dashboard request failed; refresh the tab and retry"
        : ("HTTP " + evt.detail.xhr.status)));
    const toast = document.createElement("div");
    toast.className = "toast" + (ok ? "" : " error");
    document.body.appendChild(toast);
    const dismiss = () => {
      toast.classList.remove("show");
      setTimeout(() => toast.remove(), 300);
    };
    if (ok) {
      toast.textContent = msg;
      setTimeout(dismiss, 1500);
    } else {
      // Error toast: separate body (selectable) and ✕ close button. Without
      // splitting these, clicking-to-copy would also dismiss the toast and
      // wipe the text before you can drag-select it.
      const body = document.createElement("span");
      body.className = "body";
      body.textContent = msg;
      const close = document.createElement("span");
      close.className = "close";
      close.textContent = "✕";
      close.addEventListener("click", dismiss);
      toast.appendChild(body);
      toast.appendChild(close);
    }
    requestAnimationFrame(() => toast.classList.add("show"));
  });
</script>
`;

// SSE-driven refresh: server pushes an `update` event whenever chokidar
// detects a filesystem change under queue/ or tasks/. htmx's sse extension
// reacts to that, fetches the page, and swaps in the new grid. No polling.
const REFRESH_HX_ATTRS = {
  "hx-get": "/",
  "hx-trigger": "sse:update",
  "hx-target": "#tasks-grid",
  "hx-select": "#tasks-grid",
  "hx-swap": "outerHTML",
};

export function Dashboard({ projectName, tasks, workspaceStates }: { projectName: string; tasks: Task[]; workspaceStates?: Record<string, WorkspaceState> }) {
  const byQueue = new Map<string, Task[]>();
  for (const t of tasks) {
    if (!byQueue.has(t.queueDir)) byQueue.set(t.queueDir, []);
    byQueue.get(t.queueDir)!.push(t);
  }
  const active = tasks.filter(t => t.queueDir !== "done" && t.queueDir !== "blocked" && !isWaitingOnTeam(t)).length;
  const waitingOnTeam = tasks.filter(isWaitingOnTeam).length;
  const tasksById = new Map(tasks.map(t => [t.id, t]));
  const queueOrder = [
    ...QUEUE_ORDER.filter(s => byQueue.has(s)),
    ...[...byQueue.keys()].filter(s => !QUEUE_ORDER.includes(s as typeof QUEUE_ORDER[number])).sort(),
  ];

  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <title>craft · {projectName}</title>
        <style>{STYLES}</style>
        <div dangerouslySetInnerHTML={{ __html: HTMX_HEAD }} />
      </head>
      <body hx-ext="sse" sse-connect="/events">
        {/* Modal injection target — CSS hides it when empty. */}
        <div id="modal" />
        {/* Modal open/close + Esc handler. Plain fetch instead of htmx —
            htmx's swap into #modal was finding the target but not injecting
            in our setup; vanilla DOM avoids that entirely. */}
        <script dangerouslySetInnerHTML={{ __html: `
          window.openTaskModal = async function(taskId) {
            try {
              const r = await fetch("/task/" + encodeURIComponent(taskId));
              if (!r.ok) {
                document.getElementById("modal").innerHTML =
                  '<div class="modal-backdrop" onclick="if(event.target===this)closeTaskModal()">' +
                  '<article class="modal-card"><p style="padding:1rem;color:#fca5a5">HTTP ' +
                  r.status + ' loading task ' + taskId + '</p></article></div>';
                return;
              }
              document.getElementById("modal").innerHTML = await r.text();
              // Re-process htmx attributes on the freshly-injected content so
              // any links inside the modal (Linear pills, PR pill, /open
              // rewrites in the markdown body) wire up correctly.
              if (window.htmx) window.htmx.process(document.getElementById("modal"));
            } catch (err) {
              console.error("openTaskModal failed:", err);
            }
          };
          window.closeTaskModal = function() {
            document.getElementById("modal").innerHTML = "";
          };
          document.addEventListener("keydown", (e) => {
            if (e.key === "Escape") closeTaskModal();
          });
        `}} />
        <header>
          <h1>craft · <code>{projectName}</code></h1>
          <div class="meta-line">
            {active} active · {waitingOnTeam} waiting on team · {tasks.length} total · auto-refresh 3s
          </div>
        </header>
        <div id="tasks-grid" class="columns" {...REFRESH_HX_ATTRS}>
          {queueOrder.map(s => {
            const all = byQueue.get(s)!;
            const shown = s === "done" ? all.slice(0, DONE_LIMIT) : all;
            const hidden = all.length - shown.length;
            return (
              <section class="column">
                <h2>
                  <span style={{ color: statusColor[s] ?? "#7e858d" }}>●</span>{" "}
                  {s} ({all.length})
                </h2>
                {renderQueueItems(shown, tasksById, workspaceStates ?? {})}
                {hidden > 0 && (
                  <div style={{ fontSize: "0.78rem", color: "#7e858d", padding: "0.4rem 0.2rem", fontStyle: "italic" }}>
                    …and {hidden} older — see <code>queue/done/</code>
                  </div>
                )}
              </section>
            );
          })}
        </div>
      </body>
    </html>
  );
}

function renderQueueItems(tasks: Task[], tasksById: Map<string, Task>, workspaceStates: Record<string, WorkspaceState>) {
  const parentIds = new Set(
    [...tasksById.values()].map(t => t.parent).filter((id): id is string => Boolean(id))
  );
  const parentTasks = new Map<string, Task>(
    [...tasksById.values()].filter(t => parentIds.has(t.id)).map(t => [t.id, t])
  );

  const childrenByParent = new Map<string, Task[]>();
  for (const t of tasks) {
    if (t.parent && parentTasks.has(t.parent)) {
      if (!childrenByParent.has(t.parent)) childrenByParent.set(t.parent, []);
      childrenByParent.get(t.parent)!.push(t);
    }
  }

  const rendered = new Set<string>();
  const out = [];
  for (const task of tasks) {
    if (parentTasks.has(task.id)) {
      if (rendered.has(task.id)) continue;
      rendered.add(task.id);
      const children = childrenByParent.get(task.id) ?? [];
      out.push(<ParentGroup parent={task} children={children} workspaceStates={workspaceStates} />);
      continue;
    }
    if (task.parent && parentTasks.has(task.parent)) {
      if (rendered.has(task.parent)) continue;
      rendered.add(task.parent);
      out.push(<ParentGroup parent={parentTasks.get(task.parent)!} children={childrenByParent.get(task.parent) ?? []} workspaceStates={workspaceStates} />);
      continue;
    }
    out.push(<TaskCard task={task} workspaceState={workspaceStates[task.id]} />);
  }
  return out;
}

function ParentGroup({ parent, children, workspaceStates }: { parent: Task; children: Task[]; workspaceStates: Record<string, WorkspaceState> }) {
  return (
    <div class="parent-group">
      <TaskCard task={parent} workspaceState={workspaceStates[parent.id]} />
      {children.length > 0 && (
        <div class="parent-children">
          {children.map(child => <TaskCard task={child} nested workspaceState={workspaceStates[child.id]} />)}
        </div>
      )}
    </div>
  );
}

function TaskCard({ task, nested = false, workspaceState }: { task: Task; nested?: boolean; workspaceState?: WorkspaceState }) {
  const color = statusColor[task.queueDir] ?? "#6b7280";
  const isDone = task.queueDir === "done";
  const isActive = !isDone;
  const waitingOnTeam = isWaitingOnTeam(task);
  const summaryClamp = isDone ? "lines-1" : "lines-2";
  const taskDetached = workspaceState?.detached === true;
  const taskNeedsResume = workspaceState && workspaceState.error === undefined
    && (workspaceState.exists === false || workspaceState.surface_exists === false);

  // Done tasks: trim down to identity + PR + summary. Active tasks: keep
  // the full details expander.
  // PR is now shown as a pill in the header (not in the "more" panel), so it
  // doesn't gate the expander on its own.
  const showDetails = isActive && (
    task.branch ||
    task.workflow ||
    task.waitingOn ||
    task.waitingReason ||
    task.parent ||
    task.repos.length > 0 ||
    task.milestone ||
    task.depends_on.length > 0 ||
    Object.keys(task.qa).length > 0 ||
    task.lastWorkLogEntry
  );

  return (
    <article class={`task${isDone ? " done" : ""}${nested ? " child" : ""}${waitingOnTeam ? " waiting-team" : ""}`} id={`task-${task.id}`}>
      <div class="task-header">
        <span class="task-id">
          <a
            {...inlineClick(`openTaskModal('${task.id}'); return false;`)}
            href={`/task/${task.id}`}
            title="Open the full task description"
            style={{ cursor: "pointer" }}
          >
            {task.id}
          </a>
        </span>
        <span class="badge" style={{ background: color }}>{task.queueDir}</span>
        {waitingOnTeam && <span class="wait-pill">waiting on team</span>}
        {task.linearTickets.map(t => {
          const linearUrl = `https://linear.app/${LINEAR_ORG}/issue/${t}`;
          return (
            <a
              href={linearUrl}
              hx-post={`/open?url=${encodeURIComponent(linearUrl)}`}
              hx-swap="none"
              data-toast={`opening ${t}`}
              data-toast-success={`opened ${t}`}
              {...inlineClick("event.preventDefault()")}
              class="linear-pill"
              title={`Open ${t} in your system browser (works around cmux SSO issues)`}
            >{t}</a>
          );
        })}
        {task.pr && (
          <a
            href={task.pr}
            hx-post={`/focus/pr/${task.id}`}
            hx-swap="none"
            data-toast="focusing PR"
            data-toast-success={`focused PR ${prLabel(task.pr)}`}
            {...inlineClick("event.preventDefault()")}
            class="pr-pill"
            title={`Focus the cmux PR tab for ${task.pr} (falls back to your system browser if no tab is open)`}
          >PR {prLabel(task.pr)}</a>
        )}
      </div>

      {task.bodyExcerpt && <p class={`summary ${summaryClamp}`}>{task.bodyExcerpt}</p>}

      {/* Dependency line: shown only when this task has explicit deps AND
          they're potentially actionable here (i.e. pre-merge phases).
          Mirrors what the TUI shows per node — no full graph render. */}
      {task.depends_on.length > 0
       && (task.queueDir === "pending" || task.queueDir === "approved" || task.queueDir === "blocked")
       && (
        <DepsLine task={task} />
      )}

      {isActive && (
        <div class="actions">
          {task.queueDir === "drafts" ? (
            <button
              type="button"
              class="approve"
              hx-post={`/promote-draft/${task.id}`}
              hx-swap="none"
              data-toast="promoting draft"
              data-toast-success={`promoted ${task.id}`}
              title="Move this task from queue/drafts/ to queue/pending/ for operator approval"
            >
              promote
            </button>
          ) : task.queueDir === "pending" ? (
            <button
              type="button"
              class="approve"
              hx-post={`/approve/${task.id}`}
              hx-swap="none"
              data-toast="approving"
              data-toast-success={`approved ${task.id}`}
              title="Move this task from queue/pending/ to queue/approved/ so the orchestrator can pick it up"
            >
              ✓ approve
            </button>
          ) : (
            <>
              {taskNeedsResume ? (
                <button
                  type="button"
                  class="primary"
                  hx-post={`/resume/task/${task.id}`}
                  hx-swap="none"
                  data-toast="resuming task"
                  data-toast-success={`resumed ${task.id}`}
                  title="Recreate this task's missing agent workspace or terminal"
                >
                  resume terminal
                </button>
              ) : (
                <button
                  type="button"
                  class="primary"
                  hx-post={taskDetached ? `/focus/task/${task.id}?attach=1` : `/focus/task/${task.id}`}
                  hx-swap="none"
                  data-toast={taskDetached ? "attaching" : "focused"}
                  data-toast-success={taskDetached ? `attached ${task.id}` : `focused ${task.id}`}
                >
                  {taskDetached ? "attach terminal" : "focus terminal"}
                </button>
              )}
              {waitingOnTeam ? (
                <button
                  type="button"
                  hx-post={`/unwait-team/${task.id}`}
                  hx-swap="none"
                  data-toast="clearing wait marker"
                  data-toast-success={`${task.id} active`}
                  title="Clear the waiting-on-team marker without changing the task stage"
                >
                  mark active
                </button>
              ) : (
                <button
                  type="button"
                  hx-post={`/wait-team/${task.id}`}
                  hx-swap="none"
                  data-toast="marking waiting on team"
                  data-toast-success={`${task.id} waiting on team`}
                  title="Mark this task as waiting on team without changing the task stage"
                >
                  wait team
                </button>
              )}
            </>
          )}
          {task.queueDir === "local-review" && (
            <>
              <button
                type="button"
                class="primary"
                hx-post={`/focus/diffhub/${task.id}`}
                hx-swap="none"
                data-toast="opened diffhub"
                data-toast-success="opened diffhub"
              >
                open diffhub
              </button>
              <button
                type="button"
                class="ready"
                hx-post={`/advance/${task.id}`}
                hx-swap="none"
                hx-confirm={`Advance ${task.id} to the next workflow stage?`}
                data-toast="advancing stage"
                data-toast-success={`${task.id} stage advanced`}
                title="Advance to the next workflow stage"
              >
                advance
              </button>
            </>
          )}
        </div>
      )}

      {showDetails && (
        <details class="more">
          <summary>more</summary>
          <div class="kv">
            {task.branch && (
              <>
                <b>branch</b>
                <span style={{ fontFamily: "monospace" }}>{task.branch}</span>
              </>
            )}
            {task.workflow && (
              <>
                <b>workflow</b>
                <span style={{ fontFamily: "monospace" }}>{task.workflow}</span>
              </>
            )}
            {(task.waitingOn || task.waitingReason) && (
              <>
                <b>waiting</b>
                <span>{task.waitingOn ?? task.waitingReason}{task.waitingOn && task.waitingReason ? `: ${task.waitingReason}` : ""}</span>
              </>
            )}
            {task.parent && (
              <>
                <b>parent</b>
                <span style={{ fontFamily: "monospace" }}>{task.parent}</span>
              </>
            )}
            {task.repos.length > 0 && (
              <>
                <b>repos</b>
                <span>{task.repos.join(", ")}</span>
              </>
            )}
            {task.milestone && (
              <>
                <b>milestone</b>
                <span>{task.milestone}</span>
              </>
            )}
            {task.depends_on.length > 0 && (
              <>
                <b>deps</b>
                <span>{task.depends_on.join(", ")}</span>
              </>
            )}
            {/* PR is surfaced as a pill in the card header, not duplicated here. */}
            {Object.keys(task.qa).length > 0 && (
              <>
                <b>qa</b>
                <span>{summarizeQa(task.qa)}</span>
              </>
            )}
            <>
              <b>yaml</b>
              <a
                href={`file://${task.filePath}`}
                hx-post={`/open?url=${encodeURIComponent("file://" + task.filePath)}`}
                hx-swap="none"
                data-toast="opening yaml"
                data-toast-success="opened yaml"
                {...inlineClick("event.preventDefault()")}
              >{task.filePath.split("/").slice(-2).join("/")}</a>
            </>
          </div>
          {task.lastWorkLogEntry && (
            <div class="work-log">↳ {task.lastWorkLogEntry}</div>
          )}
        </details>
      )}
    </article>
  );
}

function DepsLine({ task }: { task: Task }) {
  const unmet = new Set(task.unmetDeps);
  const blocked = unmet.size > 0;
  const cls = blocked ? "deps blocked" : "deps ready";
  const prefix = blocked
    ? `⛓ waiting on ${unmet.size}/${task.depends_on.length}: `
    : `✓ deps met: `;
  return (
    <div class={cls}>
      <span>{prefix}</span>
      {task.depends_on.map((d, i) => (
        <>
          {i > 0 && ", "}
          <code class={unmet.has(d) ? "" : "dep-met"}>{d}</code>
        </>
      ))}
    </div>
  );
}

function isWaitingOnTeam(task: Task): boolean {
  return task.waitingOn === "team";
}

function shortenUrl(u: string): string {
  return u.replace(/^https?:\/\/(www\.)?(github\.com|linear\.app)\//, "");
}

function prLabel(prUrl: string): string {
  // e.g. https://github.com/org/repo/pull/72 → #72
  const m = prUrl.match(/\/pull\/(\d+)/);
  return m ? `#${m[1]}` : "↗";
}

function summarizeQa(qa: Record<string, unknown>): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(qa)) {
    if (v === true) parts.push(k);
    else if (typeof v === "string" && v.length > 0) parts.push(`${k}=…`);
  }
  return parts.length > 0 ? parts.join(", ") : "—";
}

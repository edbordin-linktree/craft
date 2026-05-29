/**
 * craft-bk-status — Lightweight Buildkite build viewer for cmux.
 *
 * Built because cmux's in-app browser can't complete the Okta SSO flow the
 * Buildkite web UI requires. The `bk` CLI uses an API token (not browser
 * auth), so we shell out to it and render the response ourselves.
 *
 * Two access modes:
 *
 *   /pr/:owner/:repo/:number      — PR-centric. The server re-resolves
 *                                   the relevant build on every render:
 *                                     open PR  → latest build on head SHA
 *                                     merged   → latest build on merge SHA
 *                                                (pipeline-agnostic, so we
 *                                                pick up the deploy build
 *                                                automatically even though
 *                                                it lives on a different
 *                                                pipeline than the PR's CI)
 *                                   The URL is stable across the PR
 *                                   lifecycle: each push and the
 *                                   post-merge deploy all appear here.
 *
 *   /build/:org/:pipeline/:number — Direct deep link to one specific build.
 *                                   Useful when triggered-build cards link
 *                                   to downstream builds.
 *
 * Bind: 127.0.0.1 only (no auth).
 */

import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";
import { render } from "preact-render-to-string";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    port: { type: "string", default: "27435" },
    host: { type: "string", default: "127.0.0.1" },
  },
  allowPositionals: false,
});
const port = Number(values.port);
const host = values.host!;

// ---------- types ----------

interface BkBuild {
  number: number;
  state: string;
  branch: string;
  commit: string;
  message?: string;
  web_url?: string;
  started_at?: string;
  finished_at?: string;
  created_at?: string;
  jobs?: BkJob[];
  pipeline?: { slug?: string; name?: string };
  creator?: { name?: string };
}

interface BkJob {
  id: string;
  type?: string;
  name?: string;
  step_key?: string;
  state?: string;
  started_at?: string;
  finished_at?: string;
  web_url?: string;
  triggered_build?: {
    id?: string;
    number?: number;
    url?: string;
    web_url?: string;
    pipeline?: { slug?: string };
  };
}

interface GhCheck {
  name: string;
  link?: string;
  detailsUrl?: string;
  bucket?: string;
  status?: string;
  conclusion?: string;
  workflow?: string;
}

interface GhPrSummary {
  state: "OPEN" | "CLOSED" | "MERGED";
  isDraft?: boolean;
  headRefName?: string;
  headRefOid?: string;
  mergeCommit?: { oid?: string };
  checks?: GhCheck[];
}

// ---------- shell-out helpers ----------

function bk(...args: string[]): { ok: boolean; stdout: string; stderr: string } {
  const r = spawnSync("bk", args, { encoding: "utf-8" });
  return {
    ok: r.status === 0,
    stdout: (r.stdout ?? "").toString(),
    stderr: (r.stderr ?? "").toString(),
  };
}

function gh(...args: string[]): { ok: boolean; stdout: string; stderr: string } {
  const r = spawnSync("gh", args, { encoding: "utf-8" });
  return {
    ok: r.status === 0,
    stdout: (r.stdout ?? "").toString(),
    stderr: (r.stderr ?? "").toString(),
  };
}

/** macOS `open` shell-out — used to route the Buildkite web-UI link to the
 *  system default browser, since cmux's in-app browser cannot complete
 *  the Okta SSO flow. */
function openExternal(rawUrl: string): { ok: boolean; error?: string } {
  let u: URL;
  try { u = new URL(rawUrl); }
  catch (err) { return { ok: false, error: `invalid URL: ${String(err)}` }; }
  if (!["http:", "https:", "file:"].includes(u.protocol)) {
    return { ok: false, error: `refused: only http/https/file allowed (got ${u.protocol})` };
  }
  const r = spawnSync("open", [rawUrl], { encoding: "utf-8" });
  if (r.status !== 0) {
    return { ok: false, error: (r.stderr ?? "").toString().trim() || `open exited ${r.status}` };
  }
  return { ok: true };
}

// ---------- build resolution ----------

function fetchBuild(org: string, pipeline: string, number: string | number): BkBuild | { error: string } {
  const r = bk("build", "view", String(number), "--pipeline", `${org}/${pipeline}`, "--json");
  if (!r.ok) return { error: r.stderr.trim() || "bk build view failed" };
  try { return JSON.parse(r.stdout) as BkBuild; }
  catch (err) { return { error: `parse bk JSON: ${String(err)}` }; }
}

function ghPrView(owner: string, repo: string, number: string): GhPrSummary | { error: string } {
  const r = gh(
    "pr", "view", number,
    "--repo", `${owner}/${repo}`,
    "--json", "state,isDraft,headRefName,headRefOid,mergeCommit,statusCheckRollup",
  );
  if (!r.ok) return { error: r.stderr.trim() || `gh pr view exited` };
  try {
    const parsed = JSON.parse(r.stdout) as Omit<GhPrSummary, "checks"> & { statusCheckRollup?: GhCheck[] };
    return {
      state: parsed.state,
      isDraft: parsed.isDraft,
      headRefName: parsed.headRefName,
      headRefOid: parsed.headRefOid,
      mergeCommit: parsed.mergeCommit,
      checks: parsed.statusCheckRollup,
    };
  } catch (err) {
    return { error: `parse gh JSON: ${String(err)}` };
  }
}

function ghPrChecks(prRef: string): GhCheck[] | { error: string } {
  const r = gh("pr", "checks", prRef, "--json", "link,name,bucket,status,conclusion,workflow");
  if (!r.ok) return { error: r.stderr.trim() || `gh pr checks exited` };
  try { return JSON.parse(r.stdout) as GhCheck[]; }
  catch (err) { return { error: `parse gh JSON: ${String(err)}` }; }
}

function pickBkLinkFromChecks(checks: GhCheck[] | undefined): string | null {
  if (!checks) return null;
  for (const c of checks) {
    const link = (c as { link?: string; detailsUrl?: string }).link
      ?? (c as { detailsUrl?: string }).detailsUrl
      ?? "";
    if (typeof link === "string" && /^https?:\/\/buildkite\.com\//.test(link)) return link;
  }
  return null;
}

/** Extract `(org, pipeline, number)` from a Buildkite build URL. */
function parseBkUrl(url: string): { org: string; pipeline: string; number: string } | null {
  const m = url.match(/^https?:\/\/buildkite\.com\/([^/]+)\/([^/]+)\/builds\/(\d+)/);
  if (!m) return null;
  return { org: m[1], pipeline: m[2], number: m[3] };
}

interface ResolvedBuild { build: BkBuild; org: string; pipeline: string; number: string; mode: "head" | "merge" | "fallback"; }

/**
 * Resolve "the BK build the operator currently cares about for PR <n>".
 *
 *   open / draft → latest build for the PR head commit
 *   merged       → latest build for the merge commit (pipeline-agnostic, so
 *                  the post-merge deploy build is picked up even though it
 *                  lives on a different pipeline than the PR CI)
 *   closed       → fall back to checks the PR was attached to
 *
 * Uses `bk build list --commit <sha>` because it's pipeline-agnostic. Each
 * `bk` query scopes to the org we picked up from the PR's status checks.
 */
function resolvePrBuild(owner: string, repo: string, number: string): ResolvedBuild | { error: string } {
  const pr = ghPrView(owner, repo, number);
  if ("error" in pr) return pr;

  // Pick a BK org/pipeline hint from any PR check. If none yet (build hasn't
  // started), we still try the user's default `bk` org.
  let bkOrgHint: string | null = null;
  let bkPipelineHint: string | null = null;
  const bkLink = pickBkLinkFromChecks(pr.checks);
  if (bkLink) {
    const p = parseBkUrl(bkLink);
    if (p) { bkOrgHint = p.org; bkPipelineHint = p.pipeline; }
  }

  // Pick the commit to query.
  let targetSha: string;
  let mode: "head" | "merge";
  if (pr.state === "MERGED" && pr.mergeCommit?.oid) {
    targetSha = pr.mergeCommit.oid;
    mode = "merge";
  } else if (pr.headRefOid) {
    targetSha = pr.headRefOid;
    mode = "head";
  } else {
    return { error: `PR has no headRefOid or mergeCommit; cannot resolve a BK build` };
  }

  const args = ["build", "list", "--commit", targetSha, "--json"];
  if (bkOrgHint) args.push("--org", bkOrgHint);

  const r = bk(...args);
  if (!r.ok) return { error: r.stderr.trim() || "bk build list failed" };
  let builds: BkBuild[];
  try { builds = JSON.parse(r.stdout) as BkBuild[]; }
  catch (err) { return { error: `parse bk list JSON: ${String(err)}` }; }
  if (!Array.isArray(builds) || builds.length === 0) {
    const shortSha = targetSha.slice(0, 8);
    return {
      error: mode === "merge"
        ? `no Buildkite build found yet for merge commit ${shortSha} — deploy may not have started`
        : `no Buildkite build found yet for head commit ${shortSha} — CI may not have started`,
    };
  }

  const latest = builds[0]; // bk lists newest-first
  const pipelineSlug = latest.pipeline?.slug ?? bkPipelineHint ?? "?";
  const orgSlug = bkOrgHint ?? "?";
  return {
    build: latest,
    org: orgSlug,
    pipeline: pipelineSlug,
    number: String(latest.number),
    mode,
  };
}

// ---------- rendering ----------

const STYLES = `
  body { background:#0b0d10; color:#e6e8eb; font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif; padding:1rem; margin:0; font-size:0.9rem; }
  a { color:#93c5fd; text-decoration:none; }
  a:hover { text-decoration:underline; }
  header { display:flex; gap:0.8rem; align-items:baseline; flex-wrap:wrap; border-bottom:1px solid #1f242a; padding-bottom:0.7rem; margin-bottom:0.7rem; }
  h1 { font-size:1.05rem; margin:0; font-weight:600; }
  h1 code { font-family:'SF Mono',monospace; color:#93c5fd; }
  .meta { color:#7e858d; font-size:0.8rem; }
  .state { padding:0.1rem 0.55rem; border-radius:999px; font-size:0.72rem; font-weight:600; text-transform:uppercase; }
  .state-passed,.state-finished { background:#14532d; color:#86efac; }
  .state-failed,.state-failing,.state-timed_out,.state-timing_out { background:#4c1d1d; color:#fca5a5; }
  .state-running,.state-started { background:#1e3a5f; color:#93c5fd; }
  .state-scheduled,.state-waiting,.state-pending,.state-assigned,.state-accepted { background:#3f3f46; color:#d4d4d8; }
  .state-canceled,.state-canceling { background:#3f3f46; color:#9ca3af; }
  .state-blocked { background:#3f2f08; color:#fbbf24; }
  .state-broken,.state-skipped,.state-unblocked { background:#1a1f25; color:#7e858d; }
  .state-unknown { background:#374151; color:#9ca3af; }
  table { width:100%; border-collapse:collapse; margin-top:0.5rem; }
  th, td { padding:0.35rem 0.6rem; text-align:left; font-size:0.83rem; border-bottom:1px solid #1f242a; }
  th { color:#97a0aa; font-weight:500; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.04em; }
  td.dur { font-variant-numeric:tabular-nums; color:#97a0aa; text-align:right; white-space:nowrap; }
  td.name { font-family:'SF Mono',monospace; color:#c9ced4; }
  td.name code { background:#1a1f25; padding:0.05rem 0.3rem; border-radius:3px; color:#f8a978; }
  section.trig { margin-top:1.2rem; padding-top:0.7rem; border-top:1px dashed #1f242a; }
  section.trig h2 { font-size:0.78rem; text-transform:uppercase; color:#7e858d; letter-spacing:0.05em; margin:0 0 0.4rem 0; font-weight:600; }
  .empty { color:#7e858d; font-style:italic; padding:0.6rem 0; font-size:0.83rem; }
  .err { background:#1f0f0f; border:1px solid #4c1d1d; color:#fca5a5; padding:0.7rem 0.9rem; border-radius:6px; margin:1rem 0; font-family:'SF Mono',monospace; font-size:0.82rem; white-space:pre-wrap; }
  .pr-meta { font-size:0.78rem; color:#7e858d; }
`;

function fmtDuration(start?: string, end?: string): string {
  if (!start) return "";
  const s = new Date(start).getTime();
  const e = end ? new Date(end).getTime() : Date.now();
  const ms = e - s;
  if (ms < 0 || !isFinite(ms)) return "";
  const sec = Math.floor(ms / 1000);
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  if (m < 60) return `${m}m ${sec % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

function stateClass(s?: string): string {
  if (!s) return "state state-unknown";
  return `state state-${s.toLowerCase()}`;
}

function BuildBody({ build }: { build: BkBuild }) {
  const jobs = build.jobs ?? [];
  const candidateJobs = jobs.filter(j => j.type !== "waiter" && j.type !== "manual");
  const isSkipped = (j: BkJob) => j.state === "broken" || j.state === "skipped";
  const realJobs = candidateJobs.filter(j => !isSkipped(j));
  const skippedJobs = candidateJobs.filter(isSkipped);
  const triggered = jobs.filter(j => j.triggered_build?.web_url || j.triggered_build?.number);

  return (
    <>
      <table>
        <thead>
          <tr>
            <th>Step</th>
            <th>State</th>
            <th style={{ textAlign: "right" }}>Duration</th>
          </tr>
        </thead>
        <tbody>
          {realJobs.length === 0 && (
            <tr><td colSpan={3} class="empty">no jobs yet</td></tr>
          )}
          {realJobs.map(j => (
            <tr>
              <td class="name">
                {j.step_key ? <code>{j.step_key}</code> : null}
                {j.step_key && j.name ? " " : ""}
                {j.name || (j.step_key ? "" : (j.id ?? "?"))}
              </td>
              <td><span class={stateClass(j.state)}>{j.state ?? "?"}</span></td>
              <td class="dur">{fmtDuration(j.started_at, j.finished_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      {skippedJobs.length > 0 && (
        <details style={{ marginTop: "0.6rem", fontSize: "0.78rem", color: "#7e858d" }}>
          <summary style={{ cursor: "pointer", userSelect: "none" }}>
            ↳ {skippedJobs.length} step(s) skipped (broken/conditional)
          </summary>
          <ul style={{ margin: "0.3rem 0 0 1rem", paddingLeft: 0, listStyle: "disc" }}>
            {skippedJobs.map(j => (
              <li style={{ fontFamily: "'SF Mono', monospace" }}>
                {j.step_key || j.name || j.id} — <span style={{ opacity: 0.6 }}>{j.state}</span>
              </li>
            ))}
          </ul>
        </details>
      )}

      <section class="trig">
        <h2>Triggered builds</h2>
        {triggered.length === 0
          ? <div class="empty">no downstream pipelines triggered yet</div>
          : (
            <table>
              <thead>
                <tr>
                  <th>Triggered from</th>
                  <th>Pipeline / #</th>
                  <th>State</th>
                </tr>
              </thead>
              <tbody>
                {triggered.map(j => {
                  const tb = j.triggered_build!;
                  const url = tb.web_url ?? tb.url ?? "";
                  const slug = tb.pipeline?.slug ?? "?";
                  const parsed = url ? parseBkUrl(url) : null;
                  const internal = parsed ? `/build/${parsed.org}/${parsed.pipeline}/${parsed.number}` : null;
                  return (
                    <tr>
                      <td class="name">{j.step_key ?? j.name ?? j.id}</td>
                      <td>
                        {internal
                          ? <a href={internal}>{slug} #{tb.number}</a>
                          : <span>{slug} #{tb.number ?? "?"}</span>}
                      </td>
                      <td><span class={stateClass(j.state)}>{j.state ?? "?"}</span></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
      </section>
    </>
  );
}

function BuildPage({ tickPath, title, externalUrl, build, prSummary, error }: {
  tickPath: string;
  title: string;
  externalUrl?: string;
  build: BkBuild | null;
  prSummary?: { owner: string; repo: string; number: string; state: string; isDraft?: boolean; resolvedFrom: "head" | "merge" | "fallback"; };
  error?: string;
}) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <title>{title}</title>
        <style>{STYLES}</style>
        <script src="https://unpkg.com/htmx.org@2.0.4" integrity="sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+" crossorigin="anonymous" />
      </head>
      <body>
        <header>
          <h1>
            {prSummary ? (
              <>
                <code>{prSummary.owner}/{prSummary.repo}#{prSummary.number}</code>{" "}
                <span class={stateClass(prSummary.state === "MERGED" ? "passed" : prSummary.state === "CLOSED" ? "canceled" : "running")}>
                  {prSummary.isDraft ? "DRAFT" : prSummary.state}
                </span>
              </>
            ) : null}
          </h1>
          {build ? <span class={stateClass(build.state)}>{build.state ?? "?"}</span> : null}
          <span class="meta">
            {build?.pipeline?.slug ? `${build.pipeline.slug} ` : ""}
            {build ? `#${build.number} · ` : ""}
            {build?.branch ? `${build.branch} · ` : ""}
            {build?.commit ? `${build.commit.slice(0, 8)} · ` : ""}
            {build?.creator?.name ? `by ${build.creator.name} · ` : ""}
            {prSummary ? <span class="pr-meta">resolved from {prSummary.resolvedFrom} commit · </span> : ""}
            {externalUrl ? (
              <a
                href={externalUrl}
                hx-post={`/open?url=${encodeURIComponent(externalUrl)}`}
                hx-swap="none"
                title="Open the Buildkite web UI in your system browser (cmux's in-app browser cannot complete Okta SSO)"
              >open in Buildkite ↗</a>
            ) : null}
          </span>
        </header>

        {error ? <div class="err">{error}</div> : null}

        <div
          id="body"
          hx-get={tickPath}
          hx-trigger="every 5s"
          hx-swap="innerHTML"
        >
          {build ? <BuildBody build={build} /> : null}
        </div>
      </body>
    </html>
  );
}

function Index() {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <title>craft-bk-status</title>
        <style>{STYLES}</style>
      </head>
      <body>
        <header><h1>craft-bk-status</h1></header>
        <p class="meta">
          PR-centric view: <code>/pr/&lt;owner&gt;/&lt;repo&gt;/&lt;number&gt;</code> — re-resolves the relevant build on every tick (latest CI build while open, deploy build once merged).
        </p>
        <p class="meta">
          Direct deep link: <code>/build/&lt;org&gt;/&lt;pipeline&gt;/&lt;number&gt;</code>.
        </p>
        <p class="meta">Typically opened by the orchestrator via <code>show-build-status</code>.</p>
      </body>
    </html>
  );
}

function htmlResponse(body: string, status = 200): Response {
  return new Response(`<!doctype html>\n${body}`, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ---------- server ----------

const server = Bun.serve({
  port,
  hostname: host,
  fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/healthz") {
      return new Response("ok", { headers: { "content-type": "text/plain" } });
    }

    if (url.pathname === "/open" && req.method === "POST") {
      const target = url.searchParams.get("url");
      if (!target) return jsonResponse({ ok: false, error: "missing ?url" }, 400);
      const r = openExternal(target);
      return jsonResponse(r, r.ok ? 200 : 502);
    }

    if (url.pathname === "/") {
      return htmlResponse(render(<Index />));
    }

    // ---- PR-centric routes ----
    // /pr/:owner/:repo/:number
    let m = url.pathname.match(/^\/pr\/([^/]+)\/([^/]+)\/(\d+)\/?$/);
    if (m) {
      const [, owner, repo, number] = m;
      const resolved = resolvePrBuild(owner, repo, number);
      const error = "error" in resolved ? resolved.error : undefined;
      const build = "error" in resolved ? null : resolved.build;
      const prSummary = "error" in resolved
        ? { owner, repo, number, state: "?", resolvedFrom: "fallback" as const }
        : { owner, repo, number, state: build?.state ?? "?", resolvedFrom: resolved.mode };
      const externalUrl = build?.web_url
        ?? (("error" in resolved) ? undefined : `https://buildkite.com/${resolved.org}/${resolved.pipeline}/builds/${resolved.number}`);
      const title = `${owner}/${repo}#${number} — ${build?.state ?? error ?? "?"}`;
      return htmlResponse(render(
        <BuildPage
          tickPath={`/tick/pr/${owner}/${repo}/${number}`}
          title={title}
          externalUrl={externalUrl}
          build={build}
          prSummary={prSummary}
          error={error}
        />,
      ));
    }

    // /tick/pr/:owner/:repo/:number — htmx swap target
    m = url.pathname.match(/^\/tick\/pr\/([^/]+)\/([^/]+)\/(\d+)\/?$/);
    if (m) {
      const [, owner, repo, number] = m;
      const resolved = resolvePrBuild(owner, repo, number);
      if ("error" in resolved) return htmlResponse(`<div class="err">${resolved.error}</div>`);
      return htmlResponse(render(<BuildBody build={resolved.build} />));
    }

    // ---- Direct-link routes ----
    // /build/:org/:pipeline/:number
    m = url.pathname.match(/^\/build\/([^/]+)\/([^/]+)\/(\d+)\/?$/);
    if (m) {
      const [, org, pipeline, number] = m;
      const result = fetchBuild(org, pipeline, number);
      const error = "error" in result ? result.error : undefined;
      const build = "error" in result ? null : result;
      const externalUrl = build?.web_url ?? `https://buildkite.com/${org}/${pipeline}/builds/${number}`;
      const title = `${pipeline} #${number} (${build?.state ?? "?"})`;
      return htmlResponse(render(
        <BuildPage
          tickPath={`/tick/${org}/${pipeline}/${number}`}
          title={title}
          externalUrl={externalUrl}
          build={build}
          error={error}
        />,
      ));
    }

    // /tick/:org/:pipeline/:number
    m = url.pathname.match(/^\/tick\/([^/]+)\/([^/]+)\/(\d+)\/?$/);
    if (m) {
      const [, org, pipeline, number] = m;
      const result = fetchBuild(org, pipeline, number);
      if ("error" in result) return htmlResponse(`<div class="err">${result.error}</div>`);
      return htmlResponse(render(<BuildBody build={result} />));
    }

    // ---- Legacy redirect from earlier prototype ----
    if (url.pathname === "/by-pr" && req.method === "GET") {
      const prUrl = url.searchParams.get("url");
      if (!prUrl) return htmlResponse(render(<Index />), 400);
      // Parse https://github.com/<owner>/<repo>/pull/<n>
      const pm = prUrl.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
      if (!pm) return htmlResponse(`<pre class="err">unparsable PR url: ${prUrl}</pre>`, 400);
      return Response.redirect(`/pr/${pm[1]}/${pm[2]}/${pm[3]}`, 302);
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(`craft-bk-status → http://${host}:${server.port}`);

const shutdown = () => { server.stop(); process.exit(0); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { join } from "path";
import matter from "gray-matter";

export interface Task {
  id: string;
  status: string;
  type?: string;
  title?: string;
  parent?: string;
  workflow?: string;
  waitingOn?: string;
  waitingReason?: string;
  branch?: string;
  repos: string[];
  depends_on: string[];
  /** Subset of `depends_on` whose target tasks are not yet in done/ or
   *  archive/. Empty array means all dependencies are satisfied. */
  unmetDeps: string[];
  milestone?: string;
  pr?: string;
  filePath: string;
  linearTickets: string[];
  qa: Record<string, unknown>;
  modifiedAt: Date;
  bodyExcerpt: string;
  lastWorkLogEntry?: string;
  frontmatter: Record<string, unknown>;
  /** Queue subdirectory the task currently lives in (source of truth, since
   *  `status:` can lag behind moves). */
  queueDir: string;
}

const QUEUE_DIRS = [
  "drafts",
  "in-progress",
  "diffhub-review",
  "waiting",
  "approved",
  "pending",
  "blocked",
  "done",
] as const;

export const QUEUE_ORDER = QUEUE_DIRS;

const LINEAR_PATTERN = /\b(TRU|LIN|ENG)-\d+\b/g;

export function scanProject(projectDir: string): Task[] {
  const tasks: Task[] = [];
  for (const dir of discoverQueueDirs(projectDir)) {
    const dirPath = join(projectDir, "queue", dir);
    if (!existsSync(dirPath)) continue;
    let entries: string[];
    try {
      entries = readdirSync(dirPath);
    } catch {
      continue;
    }
    for (const file of entries) {
      if (!file.endsWith(".md")) continue;
      const fp = join(dirPath, file);
      let raw: string;
      try {
        raw = readFileSync(fp, "utf-8");
      } catch {
        continue;
      }
      const { data, content } = matter(raw);
      const fm = data as Record<string, unknown>;

      const contentTickets = (content.match(LINEAR_PATTERN) ?? []) as string[];
      const linearTickets = Array.from(
        new Set(contentTickets.concat(
          typeof fm.linear === "string" ? [fm.linear as string] : [],
        )),
      );

      const stat = statSync(fp);

      tasks.push({
        id: (fm.id as string) ?? file.replace(/\.md$/, ""),
        status: (fm.status as string) ?? dir,
        type: fm.type as string | undefined,
        title: fm.title as string | undefined,
        parent: fm.parent as string | undefined,
        workflow: (fm.workflow as string | undefined) ?? "standard-pr",
        waitingOn: fm.waiting_on as string | undefined,
        waitingReason: fm.waiting_reason as string | undefined,
        branch: fm.branch as string | undefined,
        repos: stringArray(fm.repos),
        depends_on: stringArray(fm.depends_on),
        unmetDeps: [], // populated after the full scan below
        milestone: fm.milestone as string | undefined,
        pr: fm.pr as string | undefined,
        filePath: fp,
        linearTickets,
        qa: (fm.qa as Record<string, unknown>) ?? {},
        modifiedAt: stat.mtime,
        bodyExcerpt: firstParagraph(content),
        lastWorkLogEntry: extractLastWorkLogEntry(content),
        frontmatter: fm,
        queueDir: dir,
      });
    }
  }

  // Compute the "done" set — task IDs that are in done/ OR anywhere under
  // archive/. A dep targeting any of these is considered satisfied, matching
  // bash's `task_deps_met` in bin/lib/queue.sh.
  const doneIds = collectDoneIds(projectDir, tasks);
  for (const t of tasks) {
    t.unmetDeps = t.depends_on.filter(d => !doneIds.has(d));
  }

  // Sort: by queueDir order, then most recently modified first inside each.
  return tasks.sort((a, b) => {
    const da = queueRank(a.queueDir);
    const db = queueRank(b.queueDir);
    if (da !== db) return da - db;
    const aw = Boolean(a.waitingOn || a.waitingReason);
    const bw = Boolean(b.waitingOn || b.waitingReason);
    if (aw !== bw) return aw ? 1 : -1;
    return b.modifiedAt.getTime() - a.modifiedAt.getTime();
  });
}

function discoverQueueDirs(projectDir: string): string[] {
  const queueRoot = join(projectDir, "queue");
  const found = new Set<string>();
  for (const dir of QUEUE_DIRS) {
    if (existsSync(join(queueRoot, dir))) found.add(dir);
  }
  let entries: string[] = [];
  try {
    entries = readdirSync(queueRoot);
  } catch {
    return [...found];
  }
  for (const entry of entries) {
    if (entry === "archive") continue;
    let stat;
    try { stat = statSync(join(queueRoot, entry)); } catch { continue; }
    if (stat.isDirectory()) found.add(entry);
  }
  return [...found].sort((a, b) => queueRank(a) - queueRank(b) || a.localeCompare(b));
}

function queueRank(queueDir: string): number {
  const idx = QUEUE_DIRS.indexOf(queueDir as typeof QUEUE_DIRS[number]);
  return idx === -1 ? 100 : idx;
}

function stringArray(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(String);
  if (typeof value === "string" && value.trim()) return [value.trim()];
  return [];
}

/**
 * Collect IDs of tasks that count as "complete" for dependency-satisfaction
 * purposes. Includes everything in queue/done/ (already in `tasks`) plus
 * anything archived under queue/archive/<milestone>/ (which we don't render
 * but still need to recognise as satisfied deps).
 */
function collectDoneIds(projectDir: string, tasks: Task[]): Set<string> {
  const ids = new Set<string>();
  for (const t of tasks) {
    if (t.queueDir === "done") ids.add(t.id);
  }
  const archiveRoot = join(projectDir, "queue", "archive");
  if (!existsSync(archiveRoot)) return ids;
  // archive/ holds milestone subdirs; each contains a flat list of .md files.
  let milestones: string[];
  try {
    milestones = readdirSync(archiveRoot);
  } catch {
    return ids;
  }
  for (const ms of milestones) {
    const msDir = join(archiveRoot, ms);
    let stat;
    try { stat = statSync(msDir); } catch { continue; }
    if (!stat.isDirectory()) continue;
    let files: string[];
    try { files = readdirSync(msDir); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith(".md")) continue;
      // Cheap path: filename without extension == task id. Avoids parsing.
      ids.add(f.replace(/\.md$/, ""));
    }
  }
  return ids;
}

function firstParagraph(content: string): string {
  // Skip leading whitespace + skip the first ## heading; grab the next non-empty paragraph.
  const lines = content.split("\n");
  let out: string[] = [];
  let inPara = false;
  for (const line of lines) {
    if (line.startsWith("## ")) {
      if (out.length > 0) break;
      continue;
    }
    if (line.trim() === "") {
      if (inPara) break;
      continue;
    }
    inPara = true;
    out.push(line.trim());
    if (out.join(" ").length > 200) break;
  }
  const joined = out.join(" ");
  return joined.length > 220 ? joined.slice(0, 217) + "…" : joined;
}

function extractLastWorkLogEntry(content: string): string | undefined {
  const i = content.indexOf("## Work Log");
  if (i === -1) return;
  const log = content.slice(i);
  // Last "### " heading + its first non-empty line.
  const headings = [...log.matchAll(/^### (.+)$/gm)];
  if (headings.length === 0) return;
  const last = headings[headings.length - 1];
  return last[1].trim();
}

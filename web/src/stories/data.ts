// Datos de ejemplo (ficticios) para las historias y las capturas; son los mismos de DESIGN.md.
import type {
  ActivityProps, ChatItemVM, DiffFileVM, FailedCheckVM, FeedbackCommentVM, FindingVM, MacInfo, MergeProps, Person,
  PRRowVM, PRSectionVM, ProgressVM, ReviewProps, SettingsProps,
} from "../ui/screens/types";

export const people = {
  laura: { name: "Laura Méndez", login: "lmendez", initials: "LM", color: "#C42B1F" },
  tomas: { name: "Tomás Ruiz", login: "truiz", initials: "TR", color: "#12793A" },
  ana: { name: "Ana Paz", login: "apaz", initials: "AP", color: "#2D4EFF" },
} satisfies Record<string, Person>;

export const macOnline: MacInfo = { name: "Diego's MacBook Pro", online: true, detail: "Connected · updated just now" };
export const macOffline: MacInfo = { name: "Diego's MacBook Pro", online: false, detail: "Offline · last seen 8:12 AM" };

const row491: PRRowVM = {
  id: "web-app#491", title: "Add CSV export to the monthly reports page", repo: "web-app", number: 491, branch: "develop",
  age: "8 min", additions: 214, deletions: 38, leading: { kind: "avatar", person: people.laura },
  action: { kind: "review", label: "Review" },
};
const row317: PRRowVM = {
  id: "api#317", title: "Refresh expired sessions without logging users out", repo: "api", number: 317, branch: "main",
  age: "12 min", additions: 46, deletions: 12, leading: { kind: "avatar", person: people.tomas },
  status: { kind: "agents", text: "2 agents · on devbox" }, action: { kind: "reviewing", label: "Reviewing…" },
};
const row482: PRRowVM = {
  id: "web-app#482", title: "Cache dashboard queries per team", repo: "web-app", number: 482, branch: "main", age: "1h",
  additions: 131, deletions: 54, leading: { kind: "avatar", person: people.ana },
  action: { kind: "comments", label: "4 comments" },
};

export const reviewSections: PRSectionVM[] = [
  { id: "review", title: "To Review", count: 2, collapsed: false, rows: [row491, row317] },
  { id: "updated", title: "Updated Since My Review", count: 1, collapsed: false, rows: [row482] },
];

export const reviewSectionsOffline: PRSectionVM[] = reviewSections.map((s) => ({
  ...s, rows: s.rows.map((r) => ({ ...r, disabled: true })),
}));

export const mineSections: PRSectionVM[] = [
  {
    id: "feedback", title: "My PRs with Feedback", count: 1, collapsed: false, rows: [{
      id: "web-app#475", title: "Speed up the monthly report export", repo: "web-app", number: 475, branch: "main", age: "2h",
      additions: 88, deletions: 31, leading: { kind: "state", state: "feedback" },
      status: { kind: "changes", text: "Changes requested · 2 comments" }, action: { kind: "respond", label: "Respond" },
    }],
  },
  {
    id: "ready", title: "Ready to Merge", count: 1, collapsed: false, rows: [{
      id: "api#322", title: "Make payment retries idempotent", repo: "api", number: 322, branch: "main", age: "40 min",
      additions: 96, deletions: 14, leading: { kind: "state", state: "ready" },
      status: { kind: "approved", text: "Approved by 2 · checks passing" }, action: { kind: "merge", label: "Merge…" },
    }],
  },
  {
    id: "failing", title: "CI Failing", count: 1, collapsed: false, rows: [{
      id: "web-app#488", title: "Move report jobs to the new queue", repo: "web-app", number: 488, branch: "main", age: "20 min",
      additions: 57, deletions: 22, leading: { kind: "state", state: "failing" },
      status: { kind: "failed", text: "2 checks failed" }, action: { kind: "fixci", label: "Fix CI" },
    }],
  },
  { id: "waiting", title: "Waiting for Review", count: 2, collapsed: true, rows: [] },
];

export const findings: FindingVM[] = [
  {
    id: "f1", severity: "high", location: "src/auth/session.ts:88", title: "Expired refresh tokens are retried forever",
    text: "When the refresh token is already expired, `refreshSession` retries on every request instead of signing the user out. Stop after the first 401 and clear the session.",
    included: true,
  },
  {
    id: "f2", severity: "medium", location: "src/auth/middleware.ts:42", title: "Race between two refreshes",
    text: "Two parallel requests can both start a refresh. Share the in-flight promise so only one refresh runs at a time.",
    included: true,
  },
  {
    id: "f3", severity: "low", location: "src/auth/cookies.ts:17", title: "Cookie max-age is hard-coded",
    text: "The cookie lifetime repeats the session TTL as a literal. Read it from `SESSION_TTL` so they can't drift.",
    included: true,
  },
  {
    id: "f4", severity: "low", location: "tests/session.test.ts:120", title: "Test name doesn't match what it checks",
    text: "The test says it checks logout but asserts the refresh call count.", included: false,
  },
];

export const reviewPR: ReviewProps["pr"] = {
  repoFull: "acme/api", number: 317, title: "Refresh expired sessions without logging users out", author: people.tomas,
  age: "12 min", additions: 46, deletions: 12, head: "fix/session-expiry", base: "main", files: 5,
};

export const reviewSummary: ReviewProps["summary"] = {
  text: "Expired sessions now refresh in the background instead of logging people out. The flow works, but an expired refresh token is retried forever and two requests can refresh at once.",
  meta: "2 agents · 3m 40s",
};

export const respondPR = { repoFull: "acme/web-app", number: 475, title: "Speed up the monthly report export" };
export const fixciPR = { repoFull: "acme/web-app", number: 488, title: "Move report jobs to the new queue" };

export const comments: FeedbackCommentVM[] = [
  {
    id: "c1", author: people.laura, location: "src/reports/export.ts:57",
    text: "This loads every row in memory before writing the CSV. Can we stream it instead?", selected: true,
  },
  { id: "c2", author: people.laura, location: "src/reports/export.ts:112", text: "Please add a test for an empty month.", selected: true },
];

export const progressRespond: ProgressVM = {
  title: "Claude is fixing 2 comments", done: false, elapsed: "2:30",
  stages: [
    { label: "Analyzing", state: "done" },
    { label: "Implementing", state: "current", detail: "Editing src/reports/export.ts" },
    { label: "Running tests", state: "pending" },
  ],
};

export const progressDone: ProgressVM = {
  title: "Fixed · tests passing", done: true, elapsed: "10:52:03",
  stages: [
    { label: "Analyzing", state: "done" },
    { label: "Implementing", state: "done" },
    { label: "Running tests", state: "done", detail: "142 passed" },
  ],
};

export const progressFixci: ProgressVM = {
  title: "Claude is fixing 2 checks", done: false, elapsed: "2:00",
  stages: [
    { label: "Analyzing", state: "current" },
    { label: "Implementing", state: "pending" },
    { label: "Running tests", state: "pending" },
  ],
};

export const failedChecks: FailedCheckVM[] = [
  {
    id: "unit", name: "unit-tests", duration: "2m 14s", log: [
      { text: "FAIL src/jobs/report-queue.test.ts", tone: "error" },
      { text: "× enqueues one job per team (38 ms)", tone: "error" },
      { text: "Expected: 3", tone: "detail" },
      { text: "Received: 0", tone: "detail" },
    ],
  },
  {
    id: "lint", name: "lint", duration: "41s", log: [
      { text: "src/jobs/report-queue.ts", tone: "detail" },
      { text: "12:7  error  'legacyQueue' is defined but never used", tone: "error" },
    ],
  },
];

export const diffFiles: DiffFileVM[] = [
  {
    id: "export", name: "export.ts", path: "src/reports/export.ts", additions: 9, deletions: 4, lines: [
      { kind: "hunk", text: "@@ -52,10 +52,16 @@ export async function exportMonth(" },
      { kind: "context", number: 52, text: "  const header = columns.map((c) => c.title).join(\",\");" },
      { kind: "context", number: 53, text: "  out.write(header + \"\\n\");" },
      { kind: "del", number: 54, text: "  const rows = await db.reports.findMany({ where: { month } });" },
      { kind: "del", number: 55, text: "  for (const row of rows) {" },
      { kind: "del", number: 56, text: "    out.write(toCsv(row) + \"\\n\");" },
      { kind: "del", number: 57, text: "  }" },
      { kind: "add", number: 54, text: "  let written = 0;" },
      { kind: "add", number: 55, text: "  const cursor = db.reports.cursor({ where: { month }, batch: 500 });" },
      { kind: "add", number: 56, text: "  for await (const batch of cursor) {" },
      { kind: "add", number: 57, text: "    for (const row of batch) {" },
      { kind: "add", number: 58, text: "      out.write(toCsv(row) + \"\\n\");" },
      { kind: "add", number: 59, text: "    }" },
      { kind: "add", number: 60, text: "  }" },
      { kind: "add", number: 61, text: "  // Streams rows so memory stays flat on big months." },
      { kind: "add", number: 62, text: "  await cursor.close();" },
      { kind: "context", number: 63, text: "  out.end();" },
      { kind: "context", number: 64, text: "}" },
    ],
  },
  {
    id: "test", name: "export.test.ts", path: "src/reports/export.test.ts", additions: 6, deletions: 0, lines: [
      { kind: "hunk", text: "@@ -40,3 +40,9 @@ describe(\"exportMonth\"" },
      { kind: "add", number: 41, text: "  it(\"writes only the header for an empty month\", async () => {" },
    ],
  },
];

export const mergeProps: Omit<MergeProps, "onBack" | "onChat" | "onFiles" | "onMethod" | "onMerge"> = {
  pr: { repoFull: "acme/api", number: 322, title: "Make payment retries idempotent", head: "feat/idempotent-retries", base: "main", additions: 96, deletions: 14 },
  description: "Payment retries now send an idempotency key, so a retry after a timeout can't charge twice. Keys live for 24 hours in Redis.",
  reviewers: [
    { person: people.laura, state: "Approved", tone: "green" },
    { person: people.tomas, state: "Approved", tone: "green" },
  ],
  checks: { text: "9 passing", tone: "green" },
  unresolved: "None",
  files: "4 changed",
  method: "squash",
  methodNotes: {
    squash: "3 commits become one commit on main.",
    merge: "Adds a merge commit and keeps all 3 commits.",
    rebase: "Replays the 3 commits on top of main.",
  },
};

export const chatReview: ChatItemVM[] = [
  { kind: "mine", id: "m1", text: "Is finding 3 really Medium? The TTL only matters if someone changes it." },
  { kind: "claude", id: "m2", text: "Fair point — it's a maintainability issue, not a bug today. I lowered it to Low and kept the comment." },
  { kind: "action", id: "a1", title: "Changed finding #3", detail: "Severity Medium → Low", undoable: true },
  { kind: "mine", id: "m3", text: "Thanks. Anything else worth flagging?" },
];

export const chatRespond: ChatItemVM[] = [
  { kind: "mine", id: "m1", text: "Use a batch size of 500 for the cursor." },
  { kind: "claude", id: "m2", text: "Done — the cursor now reads 500 rows per batch." },
  { kind: "action", id: "a1", title: "Edited fix in src/reports/export.ts", detail: "+1 −1 · tests re-running", undoable: true },
];

export const chatMerge: ChatItemVM[] = [
  { kind: "mine", id: "m1", text: "Is it safe to merge before the Redis upgrade?" },
  { kind: "claude", id: "m2", text: "Yes. It only uses SET with NX and EX, which the current Redis already supports." },
];

export const activity: Omit<ActivityProps, "onStop"> = {
  mac: macOnline,
  stats: [
    { icon: "cpu", label: "CPU", value: "38%", sub: "12 cores", fraction: 0.38, tone: "green" },
    { icon: "memorychip", label: "Memory", value: "11.2 GB", sub: "of 16 GB", fraction: 0.7, tone: "orange" },
    { icon: "internaldrive", label: "Disk", value: "212 GB", sub: "free of 512", fraction: 0.59, tone: "accent" },
  ],
  running: [
    { id: "t1", title: "Reviewing api#317", sub: "2 agents · 4:12 · ~$0.38" },
    { id: "t2", title: "Fixing CI on web-app#488", sub: "Running tests · 2:03 · ~$0.21" },
  ],
  month: {
    total: "$48.20", caption: "estimated · November", segments: [
      { label: "Reviews", count: "31", amount: "$29.10", value: 29.1, tone: "violet" },
      { label: "Fixes", count: "12", amount: "$14.60", value: 14.6, tone: "accent" },
      { label: "Chat", count: "46 msgs", amount: "$4.50", value: 4.5, tone: "neutral" },
    ],
  },
};

export const settings: Omit<SettingsProps, "onUnpair" | "onToggleNotification" | "onToggleFaceId"> = {
  mac: { ...macOnline, secure: "Connected · end-to-end encrypted" },
  notifications: [
    { id: "reviewReady", label: "Review ready", on: true },
    { id: "newPR", label: "New PR to review", on: true },
    { id: "changesRequested", label: "Changes requested on my PRs", on: true },
    { id: "readyToMerge", label: "Ready to merge", on: true },
    { id: "ciFailed", label: "CI failed on my PRs", on: true },
  ],
  requireFaceId: { id: "faceid", label: "Require Face ID for merge, push, approve and tests", on: true },
  version: "PRBar 0.1.0 (demo)",
};

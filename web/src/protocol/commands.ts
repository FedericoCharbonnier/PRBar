import { utf8, type Bytes } from "../crypto/bytes";
import {
  DecodeError, expectObject, isObject, parseJSONBytes, swiftJSON, type JSONValue,
} from "./json";

// Los tipos de PRBarWire que usa el teléfono, escritos a mano (spec W.2) y probados contra el JSON que genera la Mac
// (`web/test/fixtures/app.json`). Un `AppCommand` tiene la forma exacta del cable: la síntesis de Codable de Swift
// para un enum con valores etiquetados da `{"merge":{"confirmed":true,…}}`, y `{"status":{}}` para un caso sin
// valores. Los opcionales ausentes no se escriben. Fechas: texto ISO 8601; URLs y UUID: texto.

// --- Hojas ---

export type PRListFilter = "to-review" | "updated" | "mine" | "ready-to-merge" | "other";
export type PopoverTab = "to-review" | "mine";
export type PopoverSection =
  | "toReview" | "updatedSinceMyReview" | "otherToReview" | "myFeedback" | "readyToMerge" | "waitingForReview";
export type PRCategory = "toReview" | "updatedSinceMyReview" | "myFeedback" | "readyToMerge" | "other";
export type HistoryKind = "review" | "respond" | "merge" | "ci-fix" | "conflicts";
export type ReviewEvent = "COMMENT" | "REQUEST_CHANGES" | "APPROVE";
export type MergeMethod = "squash" | "merge" | "rebase";
export type Severity = "high" | "medium" | "low";
/** `conflicts` (Resolve Conflicts) solo se lee: el teléfono no lo empieza ni lo pushea (decisión C.9.9). */
export type RespondMode = "feedback" | "ciFix" | "conflicts";
export type NotificationSettingName =
  | "new-to-review" | "reviewed-updated" | "my-feedback" | "review-finished" | "approved-or-ci" | "ready-to-merge";
/** Fecha ISO 8601 (`2026-11-20T12:38:00Z`). */
export type ISODate = string;

/** `prbar respond select`: qué cambiar de cada comentario (los ausentes no se tocan). */
export interface RespondSelectionChange {
  implement?: boolean;
  reply?: boolean;
  replyText?: string;
  fixPlan?: string;
}

type Empty = Record<string, never>;

// --- AppCommand (solo los casos que el teléfono puede mandar, RemotePolicy.swift) ---

export interface PhoneCommandArgs {
  status: Empty;
  listPRs: { list?: PRListFilter; account?: string; tab?: PopoverTab };
  resolvePR: { pr: string };
  history: { repo?: string; kind?: HistoryKind; limit?: number; search?: string };
  historyShow: { id: string };
  refresh: Empty;
  reviewStart: { pr: string; wait: boolean };
  reviewShow: { pr: string };
  reviewEdit: { pr: string; finding: string; title?: string; body?: string };
  reviewSetIncluded: { pr: string; findings: string[]; all: boolean; included: boolean };
  reviewSetComment: { pr: string; text: string };
  reviewPublish: {
    pr: string; event: ReviewEvent; only?: string[]; withComments: boolean; allInBody: boolean; confirmed: boolean;
  };
  reviewCancel: { pr: string };
  reviewDismiss: { pr: string };
  respondStart: { pr: string; wait: boolean };
  respondShow: { pr: string };
  respondSelect: { pr: string; items: string[]; change: RespondSelectionChange };
  respondReset: { pr: string };
  respondImplement: { pr: string; wait: boolean };
  respondTest: { pr: string; wait: boolean };
  respondDiff: { pr: string };
  /** `mode`: lo que el teléfono cree que está pusheando; si la Mac tiene otra cosa, no pushea (`prbar ci push`). */
  respondPush: { pr: string; confirmed: boolean; wait: boolean; mode?: RespondMode };
  respondPushAnyway: { pr: string; confirmed: boolean; wait: boolean; mode?: RespondMode };
  respondReplyOnly: { pr: string; confirmed: boolean; wait: boolean };
  respondCancel: { pr: string };
  respondDismiss: { pr: string };
  ciList: Empty;
  ciFix: { pr: string; wait: boolean };
  usage: { month?: string };
  merge: { pr: string; method?: MergeMethod; confirmed: boolean; expectedHeadOid: string };
  mergePreview: { pr: string; method?: MergeMethod };
  mergeDismiss: { pr: string };
  resources: Empty;
  notifyList: Empty;
  notifySet: { kind: NotificationSettingName; enabled: boolean };
  notifySetEnabled: { enabled: boolean };
  chatSend: { pr: string; message: string };
  chatShow: { pr: string };
  chatUndo: { pr: string; confirmed: boolean };
  chatStop: { pr: string };
  /** `device` vacío: la Mac pone el de la sesión. */
  remoteSetPresenceRequirement: { device: string; enabled: boolean };
}

export type PhoneCommandName = keyof PhoneCommandArgs;

/** Un comando con la forma del cable: `{ merge: { pr, confirmed, … } }`. */
export type AppCommand = { [K in PhoneCommandName]: { [P in K]: PhoneCommandArgs[K] } }[PhoneCommandName];

/** El tipo de cada campo, para validar lo que se decodifica. `?` = opcional. */
type FieldType = "s" | "s?" | "b" | "i?" | "s[]" | "s[]?" | "change";

const S = "s" as const;
const B = "b" as const;
const OPT = "s?" as const;

const FIELDS: { [K in PhoneCommandName]: Record<keyof PhoneCommandArgs[K] & string, FieldType> } = {
  status: {},
  listPRs: { list: OPT, account: OPT, tab: OPT },
  resolvePR: { pr: S },
  history: { repo: OPT, kind: OPT, limit: "i?", search: OPT },
  historyShow: { id: S },
  refresh: {},
  reviewStart: { pr: S, wait: B },
  reviewShow: { pr: S },
  reviewEdit: { pr: S, finding: S, title: OPT, body: OPT },
  reviewSetIncluded: { pr: S, findings: "s[]", all: B, included: B },
  reviewSetComment: { pr: S, text: S },
  reviewPublish: { pr: S, event: S, only: "s[]?", withComments: B, allInBody: B, confirmed: B },
  reviewCancel: { pr: S },
  reviewDismiss: { pr: S },
  respondStart: { pr: S, wait: B },
  respondShow: { pr: S },
  respondSelect: { pr: S, items: "s[]", change: "change" },
  respondReset: { pr: S },
  respondImplement: { pr: S, wait: B },
  respondTest: { pr: S, wait: B },
  respondDiff: { pr: S },
  respondPush: { pr: S, confirmed: B, wait: B, mode: OPT },
  respondPushAnyway: { pr: S, confirmed: B, wait: B, mode: OPT },
  respondReplyOnly: { pr: S, confirmed: B, wait: B },
  respondCancel: { pr: S },
  respondDismiss: { pr: S },
  ciList: {},
  ciFix: { pr: S, wait: B },
  usage: { month: OPT },
  merge: { pr: S, method: OPT, confirmed: B, expectedHeadOid: S },
  mergePreview: { pr: S, method: OPT },
  mergeDismiss: { pr: S },
  resources: {},
  notifyList: {},
  notifySet: { kind: S, enabled: B },
  notifySetEnabled: { enabled: B },
  chatSend: { pr: S, message: S },
  chatShow: { pr: S },
  chatUndo: { pr: S, confirmed: B },
  chatStop: { pr: S },
  remoteSetPresenceRequirement: { device: S, enabled: B },
};

/** Los comandos que el teléfono puede mandar (los `.allowed`, `.gated` y `.dependsOnArguments` de RemotePolicy). */
export const PHONE_COMMANDS = Object.keys(FIELDS) as PhoneCommandName[];

const METHODS = ["squash", "merge", "rebase"];
/** Los campos que son enums de Swift: un valor que la Mac no conoce no decodifica allá. */
const ENUMS: Partial<Record<string, readonly string[]>> = {
  "listPRs.list": ["to-review", "updated", "mine", "ready-to-merge", "other"],
  "listPRs.tab": ["to-review", "mine"],
  "history.kind": ["review", "respond", "merge", "ci-fix", "conflicts"],
  "reviewPublish.event": ["COMMENT", "REQUEST_CHANGES", "APPROVE"],
  "merge.method": METHODS,
  "respondPush.mode": ["feedback", "ciFix"],
  "respondPushAnyway.mode": ["feedback", "ciFix"],
  "mergePreview.method": METHODS,
  "notifySet.kind": ["new-to-review", "reviewed-updated", "my-feedback", "review-finished", "approved-or-ci",
                     "ready-to-merge"],
};

export function commandName(command: AppCommand): PhoneCommandName {
  return Object.keys(command)[0] as PhoneCommandName;
}

/** Los bytes que se mandan en `req.cmd` (y que firma la prueba de presencia). */
export function encodeCommand(command: AppCommand): Bytes {
  return utf8(swiftJSON(command));
}

export function commandText(command: AppCommand): string {
  return swiftJSON(command);
}

function checkField(name: string, key: string, type: FieldType, value: unknown): void {
  const fail = () => new DecodeError(`${name}.${key} has the wrong type`);
  if (value === undefined || value === null) {
    if (type.endsWith("?")) return;
    throw new DecodeError(`${name}.${key} is missing`);
  }
  switch (type) {
    case "s":
    case "s?":
      if (typeof value !== "string") throw fail();
      if (ENUMS[`${name}.${key}`]?.includes(value) === false) throw fail();
      return;
    case "b":
      if (typeof value !== "boolean") throw fail();
      return;
    case "i?":
      if (typeof value !== "number" || !Number.isSafeInteger(value)) throw fail();
      return;
    case "s[]":
    case "s[]?":
      if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) throw fail();
      return;
    case "change": {
      if (!isObject(value)) throw fail();
      for (const [field, kind] of [["implement", "boolean"], ["reply", "boolean"], ["replyText", "string"],
                                   ["fixPlan", "string"]] as const) {
        if (value[field] !== undefined && value[field] !== null && typeof value[field] !== kind) throw fail();
      }
      return;
    }
  }
}

/** Valida un comando ya parseado (de la forma del cable). Solo acepta los que el teléfono puede mandar. */
export function validateCommand(value: unknown): AppCommand {
  const c = expectObject(value, "command");
  const keys = Object.keys(c);
  if (keys.length !== 1) throw new DecodeError("a command has exactly one case");
  const name = keys[0]!;
  if (!(name in FIELDS)) throw new DecodeError(`${name} can't be sent from the phone`);
  const args = expectObject(c[name], name);
  for (const [key, type] of Object.entries(FIELDS[name as PhoneCommandName] as Record<string, FieldType>)) {
    checkField(name, key, type, args[key]);
  }
  return c as AppCommand;
}

export function decodeCommand(data: Uint8Array | string): AppCommand {
  let parsed: unknown;
  try {
    parsed = typeof data === "string" ? JSON.parse(data) : parseJSONBytes(data);
  } catch {
    throw new DecodeError("command is not JSON");
  }
  return validateCommand(parsed);
}

// --- Política (RemotePolicy.decide) ---

export type PolicyDecision = "allowed" | "gated";

// Mac-only (denied in RemotePolicy.swift, so never phone commands): sessionList, sessionOpen, setTerminal,
// setTerminalCommand and setKeepSessionFolders open or choose a terminal, or keep folders, on the Mac (spec T.4, T.6).
// conflictsList and conflictsResolve start or list Resolve Conflicts runs, which are pushed only from the Mac (spec C.9.9).
/** Los comandos que pueden pedir Face ID, en el orden de `AppCommand.Name.allCases` (`RemotePolicy.gatedNames`). */
export const GATED_NAMES: readonly PhoneCommandName[] = [
  "reviewPublish", "respondTest", "respondPush", "respondPushAnyway", "respondReplyOnly", "merge",
  "remoteSetPresenceRequirement",
];

export function decidePolicy(command: AppCommand): PolicyDecision {
  // Merge, push y tests (ejecutan código del repo en la Mac), y todo lo que publica en GitHub como el usuario: cualquier
  // review (comment, request changes, approve) y las respuestas solas. Editar el borrador (`respondSelect`) no publica.
  if ("merge" in command || "respondPush" in command || "respondPushAnyway" in command || "respondTest" in command ||
      "reviewPublish" in command || "respondReplyOnly" in command) {
    return "gated";
  }
  // Prender "Require Face ID" no; apagarlo sí (P.8, L5).
  if ("remoteSetPresenceRequirement" in command) return command.remoteSetPresenceRequirement.enabled ? "allowed" : "gated";
  return "allowed";
}

// --- Resultados (CommandResults.swift y las hojas de WireLeaves/WireUsage/WireCI) ---

export interface OkResult {
  ok: true;
}

export interface ToolInfo {
  name: string;
  path?: string;
  custom: boolean;
}

export interface JobInfo {
  pr: string;
  kind: string;
  phase: string;
}

export interface StatusInfo {
  appVersion: string;
  refreshing: boolean;
  fetchedAt?: ISODate;
  offline: boolean;
  rateLimitedUntil?: ISODate;
  badgeCount: number;
  /** Por `PRCategory`. */
  counts: Record<string, number>;
  issues: string[];
  slackIssues: string[];
  jobs: JobInfo[];
  accounts: string[];
  tools: ToolInfo[];
  blockedReason?: string;
  updateAvailable?: string;
  tabCounts?: Record<string, number>;
  sectionCounts?: Record<string, number>;
}

export interface PRInfo {
  /** `owner/repo#N`. */
  id: string;
  repo: string;
  number: number;
  title: string;
  url: string;
  author: string;
  account: string;
  category: PRCategory | (string & {});
  baseRef: string;
  headRef: string;
  isDraft: boolean;
  ci: string;
  additions: number;
  deletions: number;
  updatedAt: ISODate;
  /** Fase del review de PRBar, si hay. */
  review?: string;
  respond?: string;
  merge?: string;
  mergeError?: string;
  tab?: PopoverTab;
  section?: PopoverSection;
  authorName?: string;
  approvals?: number;
  changedFiles?: number;
}

export interface PRLink {
  pr: string;
  url: string;
}

export interface FindingInfo {
  number: number;
  id: string;
  severity: Severity;
  location: string;
  title: string;
  body: string;
  keptByFilter: boolean;
  filterReason?: string;
  included: boolean;
  edited: boolean;
  hiddenBy?: string;
}

/** Lo que Claude dice de un comentario que PRBar publicó en una review anterior (spec RM.4). */
export type PreviousStatus = "fixed" | "notFixed" | "partially" | "unclear";

export interface PreviousCommentInfo {
  id: string;
  location: string;
  text: string;
  status: PreviousStatus;
  note: string;
  github: "resolved" | "open" | "unknown";
  outdated: boolean;
}

/** La decisión que recomienda PRBar (spec RM.5). */
export interface RecommendedAction {
  event: ReviewEvent;
  reason: string;
}

export interface ClaudeUsage {
  runs: number;
  unknownRuns: number;
  durationSeconds: number;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  costUSD?: number;
}

export interface ReviewInfo {
  pr: string;
  /** `ReviewPhase.cliName` o `"none"`. */
  phase: string;
  detail?: string;
  title?: string;
  summary?: string;
  language?: string;
  account?: string;
  outdated: boolean;
  findings: FindingInfo[];
  generalComment?: string;
  reviewURL?: string;
  logPath?: string;
  usage?: ClaudeUsage;
  /** Spec RM.6: solo con memoria (opcionales, sin subir la versión del protocolo). */
  previous?: PreviousCommentInfo[];
  reviewedSince?: string;
  recommendedAction?: RecommendedAction;
}

export interface PublishedReviewInfo {
  pr: string;
  url: string;
  /** approve, requestChanges, comment. */
  action: string;
  comments: number;
  publishedAt: ISODate;
}

export interface RespondItemInfo {
  number: number;
  id: string;
  reviewer: string;
  location: string;
  outdated: boolean;
  thread: string[];
  commentURL?: string;
  assessment: string;
  suggested: string;
  implement: boolean;
  fixPlan: string;
  reply: boolean;
  replyText: string;
  postedURL?: string;
}

export interface CommitDTO {
  item: string;
  status: string;
  sha?: string;
  summary: string;
}

export interface TestInfo {
  command: string;
  passed: boolean;
  outputTail: string;
}

export interface CICheckFailure {
  id: string;
  name: string;
  conclusion: string;
  appName?: string;
  detailsURL?: string;
  hasLog: boolean;
  durationSeconds?: number;
  logExcerpt?: string[];
}

export interface RespondInfo {
  pr: string;
  /** `RespondPhase.cliName` o `"none"`. */
  phase: string;
  detail?: string;
  runningTests: boolean;
  title?: string;
  account?: string;
  headRef?: string;
  worktree?: string;
  language?: string;
  items: RespondItemInfo[];
  fixes: number;
  replies: number;
  commits: CommitDTO[];
  diffStat?: string;
  sensitiveChanges: string[];
  tests?: TestInfo;
  pushed: boolean;
  pendingReplies: number;
  testCommand?: string;
  errorMessage?: string;
  logPath?: string;
  pushBlockedByTests: boolean;
  /** Ausente = `feedback`. */
  mode?: RespondMode;
  ciChecks?: CICheckFailure[];
  pushBlockedByCI?: string;
  usage?: ClaudeUsage;
  startedAt?: ISODate;
  totalChecks?: number;
  testSummary?: string;
  currentFile?: string;
}

export interface RespondDiff {
  pr: string;
  diffStat: string;
  diff?: string;
  truncated: boolean;
  sensitiveChanges: string[];
}

export interface HistoryEntryInfo {
  id: string;
  kind: HistoryKind;
  pr: string;
  repo: string;
  number: number;
  title: string;
  status: string;
  startedAt: ISODate;
  finishedAt?: ISODate;
  usage?: ClaudeUsage;
}

export interface PostedReplyInfo {
  item: string;
  location: string;
  url: string;
}

export interface RuleProposalInfo {
  number?: number;
  id: string;
  scope: string;
  appliesTo: string[];
  text: string;
  /** pending, saved o dismissed. */
  status: string;
}

export interface ChatMessageInfo {
  id: string;
  /** user, assistant o error. */
  role: string;
  text: string;
  createdAt: ISODate;
  changes?: string;
  undone: boolean;
  notes: string[];
  undoable: boolean;
  proposals: RuleProposalInfo[];
}

export interface ChatInfo {
  pr: string;
  /** review, respond, merge o instructions. */
  kind: string;
  readOnly: boolean;
  running: boolean;
  lockReason?: string;
  messages: ChatMessageInfo[];
  streamed: boolean;
}

export interface HistoryDetail {
  entry: HistoryEntryInfo;
  prURL: string;
  summary?: string;
  errorMessage?: string;
  findings: FindingInfo[];
  generalComment?: string;
  action?: string;
  reviewURL?: string;
  replies: PostedReplyInfo[];
  pushed: boolean;
  logPath?: string;
  canReopen: boolean;
  canOpen: boolean;
  chat?: ChatInfo;
  mergeMethod?: MergeMethod;
  headOid?: string;
}

export interface NotificationsInfo {
  enabled: boolean;
  /** Por `NotificationSettingName`. */
  kinds: Record<string, boolean>;
  deniedInMacOS: boolean;
}

export interface MergeInfo {
  pr: string;
  method: MergeMethod;
  mergedAt: ISODate;
  url: string;
}

export interface MergeReviewSummary {
  author: string;
  avatarURL?: string;
  state: "approved" | "changesRequested" | "commented" | "dismissed";
  submittedAt?: ISODate;
}

export interface MergeCheck {
  name: string;
  kind: "checkRun" | "status";
  state: "passed" | "failed" | "running" | "skipped";
  isRequired: boolean;
  url?: string;
  startedAt?: ISODate;
  completedAt?: ISODate;
}

export interface MergeChangedFile {
  path: string;
  additions: number;
  deletions: number;
  change: "added" | "modified" | "removed" | "renamed" | "copied" | "changed";
}

export interface MergeDetail {
  number: number;
  title: string;
  body: string;
  url?: string;
  author: string;
  authorAvatarURL?: string;
  baseRef: string;
  headRef: string;
  headOid: string;
  additions: number;
  deletions: number;
  commitCount?: number;
  mergeable: "mergeable" | "conflicting" | "unknown";
  status: "clean" | "hasHooks" | "unstable" | "blocked" | "behind" | "dirty" | "draft" | "unknown";
  reviewDecision: "approved" | "changesRequested" | "reviewRequired" | "none";
  reviews: MergeReviewSummary[];
  pendingReviewers: string[];
  checks: MergeCheck[];
  checksTotal: number;
  unresolvedThreads: number;
  totalThreads: number;
  checkedThreads?: number;
  files: MergeChangedFile[];
  changedFiles: number;
  incomplete?: ("reviews" | "checks" | "conversations" | "files" | "details")[];
}

export interface MergePreviewInfo {
  pr: string;
  title: string;
  url: string;
  baseRef: string;
  headRef: string;
  /** El head que se va a mergear: `merge.expectedHeadOid`. */
  headOid: string;
  commitCount?: number;
  method: MergeMethod;
  note?: string;
  deletesBranch: boolean;
  previousError?: string;
  detail?: MergeDetail;
  detailError?: string;
  /** Por qué todavía no se puede mergear; ausente = se puede. */
  problem?: string;
}

export interface ProcessActivity {
  kind: string;
  prID?: string;
  title: string;
  host?: string;
  chatSessionID?: string;
}

export interface ProcessUsage {
  pid: number;
  name: string;
  activity?: ProcessActivity;
  cpuPercent: number;
  memoryBytes: number;
  startedAt?: ISODate;
  isApp: boolean;
}

export interface ResourceUsage {
  cpuPercent: number;
  memoryBytes: number;
  processes: ProcessUsage[];
  sampledAt: ISODate;
}

export interface DiskItem {
  path: string;
  bytes: number;
  kind: "worktrees" | "updater" | "history" | "logs" | "appData";
  state: "active" | "orphan" | "cache" | "data";
  repo?: string;
  clone?: string;
  title: string;
  keptForTerminal?: boolean;
}

export interface DiskUsage {
  items: DiskItem[];
  scannedAt: ISODate;
}

export interface ResourcesInfo {
  usage: ResourceUsage;
  disk: DiskUsage;
  claudeThisMonth?: ClaudeUsage;
}

export interface CIListEntry {
  pr: string;
  title: string;
  url: string;
  account: string;
  phase?: string;
  respondInProgress: boolean;
  unavailableReason?: string;
  failedChecks?: number;
}

export interface UsageMonth {
  /** `YYYY-MM`. */
  month: string;
  usage: ClaudeUsage;
  byKind: Record<string, ClaudeUsage>;
}

export interface UsageTask {
  id: string;
  activity?: ProcessActivity;
  stages: string[];
  startedAt: ISODate;
  finishedAt: ISODate;
  usage: ClaudeUsage;
}

export interface UsageInfo {
  month: UsageMonth;
  tasks: UsageTask[];
  note: string;
}

export interface RemoteDeviceInfo {
  id: string;
  name: string;
  model: string;
  pairedAt: ISODate;
  lastSeen?: ISODate;
  online: boolean;
  requirePresence: boolean;
  notifications: boolean;
}

/** Lo que devuelve cada comando en `result`. */
export interface CommandResults {
  status: StatusInfo;
  listPRs: PRInfo[];
  resolvePR: PRLink;
  history: HistoryEntryInfo[];
  historyShow: HistoryDetail;
  refresh: OkResult;
  reviewStart: ReviewInfo;
  reviewShow: ReviewInfo;
  reviewEdit: ReviewInfo;
  reviewSetIncluded: ReviewInfo;
  reviewSetComment: ReviewInfo;
  reviewPublish: PublishedReviewInfo;
  reviewCancel: OkResult;
  reviewDismiss: OkResult;
  respondStart: RespondInfo;
  respondShow: RespondInfo;
  respondSelect: RespondInfo;
  respondReset: RespondInfo;
  respondImplement: RespondInfo;
  respondTest: RespondInfo;
  respondDiff: RespondDiff;
  respondPush: RespondInfo;
  respondPushAnyway: RespondInfo;
  respondReplyOnly: RespondInfo;
  respondCancel: OkResult;
  respondDismiss: OkResult;
  ciList: CIListEntry[];
  ciFix: RespondInfo;
  usage: UsageInfo;
  merge: MergeInfo;
  mergePreview: MergePreviewInfo;
  mergeDismiss: OkResult;
  resources: ResourcesInfo;
  notifyList: NotificationsInfo;
  notifySet: OkResult;
  notifySetEnabled: OkResult;
  chatSend: ChatInfo;
  chatShow: ChatInfo;
  chatUndo: ChatInfo;
  chatStop: ChatInfo;
  remoteSetPresenceRequirement: RemoteDeviceInfo;
}

export type ResultOf<C extends AppCommand> = CommandResults[keyof C & PhoneCommandName];

// Validación liviana: los campos obligatorios de cada tipo de primer nivel (la UI confía en el resto de la forma).
const REQUIRED: Record<string, string[]> = {
  status: ["appVersion", "refreshing", "offline", "badgeCount", "counts", "jobs"],
  pr: ["id", "repo", "number", "title", "url", "author", "category", "updatedAt"],
  link: ["pr", "url"],
  history: ["id", "kind", "pr", "title", "status", "startedAt"],
  historyDetail: ["entry", "prURL", "findings", "replies", "pushed", "canReopen", "canOpen"],
  ok: ["ok"],
  review: ["pr", "phase", "outdated", "findings"],
  published: ["pr", "url", "action", "comments", "publishedAt"],
  respond: ["pr", "phase", "runningTests", "items", "fixes", "replies", "commits", "sensitiveChanges", "pushed",
            "pendingReplies", "pushBlockedByTests"],
  diff: ["pr", "diffStat", "truncated", "sensitiveChanges"],
  ci: ["pr", "title", "url", "account", "respondInProgress"],
  usage: ["month", "tasks", "note"],
  merge: ["pr", "method", "mergedAt", "url"],
  mergePreview: ["pr", "title", "url", "baseRef", "headRef", "headOid", "method", "deletesBranch"],
  resources: ["usage", "disk"],
  notify: ["enabled", "kinds", "deniedInMacOS"],
  chat: ["pr", "kind", "readOnly", "running", "messages", "streamed"],
  device: ["id", "name", "model", "pairedAt", "online", "requirePresence"],
};

const RESULT_SHAPE: { [K in PhoneCommandName]: { shape: keyof typeof REQUIRED; array?: true } } = {
  status: { shape: "status" }, listPRs: { shape: "pr", array: true }, resolvePR: { shape: "link" },
  history: { shape: "history", array: true }, historyShow: { shape: "historyDetail" }, refresh: { shape: "ok" },
  reviewStart: { shape: "review" }, reviewShow: { shape: "review" }, reviewEdit: { shape: "review" },
  reviewSetIncluded: { shape: "review" }, reviewSetComment: { shape: "review" }, reviewPublish: { shape: "published" },
  reviewCancel: { shape: "ok" }, reviewDismiss: { shape: "ok" }, respondStart: { shape: "respond" },
  respondShow: { shape: "respond" }, respondSelect: { shape: "respond" }, respondReset: { shape: "respond" },
  respondImplement: { shape: "respond" }, respondTest: { shape: "respond" }, respondDiff: { shape: "diff" },
  respondPush: { shape: "respond" }, respondPushAnyway: { shape: "respond" }, respondReplyOnly: { shape: "respond" },
  respondCancel: { shape: "ok" }, respondDismiss: { shape: "ok" }, ciList: { shape: "ci", array: true },
  ciFix: { shape: "respond" }, usage: { shape: "usage" }, merge: { shape: "merge" },
  mergePreview: { shape: "mergePreview" }, mergeDismiss: { shape: "ok" }, resources: { shape: "resources" },
  notifyList: { shape: "notify" }, notifySet: { shape: "ok" }, notifySetEnabled: { shape: "ok" },
  chatSend: { shape: "chat" }, chatShow: { shape: "chat" }, chatUndo: { shape: "chat" }, chatStop: { shape: "chat" },
  remoteSetPresenceRequirement: { shape: "device" },
};

function requireKeys(value: unknown, shape: string, what: string): Record<string, unknown> {
  const c = expectObject(value, what);
  for (const key of REQUIRED[shape] ?? []) {
    if (c[key] === undefined || c[key] === null) throw new DecodeError(`${what}.${key} is missing`);
  }
  return c;
}

function requireArray(value: unknown, shape: string, what: string): unknown[] {
  if (!Array.isArray(value)) throw new DecodeError(`${what} is not an array`);
  value.forEach((item, i) => requireKeys(item, shape, `${what}[${i}]`));
  return value;
}

/** El `result` de `name`, con los campos obligatorios comprobados. */
export function decodeResult<K extends PhoneCommandName>(name: K, value: JSONValue | undefined): CommandResults[K] {
  const { shape, array } = RESULT_SHAPE[name];
  if (array) requireArray(value, shape, name);
  else requireKeys(value, shape, name);
  return value as unknown as CommandResults[K];
}

// --- Tópicos (RemoteState.swift) ---

export interface RemoteHome {
  status: StatusInfo;
  prs: PRInfo[];
  ci: CIListEntry[];
  /** Comentarios incluidos de un review listo, por PR. */
  findingCounts?: Record<string, number>;
}

export interface RemotePRDetail {
  pr?: PRInfo;
  review?: ReviewInfo;
  respond?: RespondInfo;
  chat?: ChatInfo;
  slackChannel?: string;
}

export interface MacSystemInfo {
  cores: number;
  memoryTotalBytes: number;
  memoryUsedBytes: number;
  diskFreeBytes: number;
  diskTotalBytes: number;
}

export interface RunningJobInfo {
  pr: string;
  kind: string;
  title: string;
  phase: string;
  startedAt?: ISODate;
  costUSD?: number;
}

export interface RemoteActivity {
  resources: ResourcesInfo;
  usage?: UsageInfo;
  history: HistoryEntryInfo[];
  system?: MacSystemInfo;
  running?: RunningJobInfo[];
}

export type RemoteTopic = { kind: "home" } | { kind: "activity" } | { kind: "pr"; id: string };

/** Máximo de tópicos por suscripción que calcula la Mac. */
export const MAX_TOPICS_PER_SUBSCRIPTION = 20;

const PR_PART = /^[\p{L}\p{N}_.-]{1,100}$/u;

/** `owner/repo#N` válido (como `RemoteTopic.init` de Swift). */
export function isPRId(id: string): boolean {
  const parts = id.split("#");
  if (parts.length !== 2) return false;
  const [repo, number] = parts as [string, string];
  if (!/^[1-9]\d*$/.test(number) || !Number.isSafeInteger(Number(number))) return false;
  const segments = repo.split("/");
  return segments.length === 2 && segments.every((s) => PR_PART.test(s));
}

export function parseTopic(text: string): RemoteTopic | null {
  if (text === "home") return { kind: "home" };
  if (text === "activity") return { kind: "activity" };
  if (!text.startsWith("pr:")) return null;
  const id = text.slice(3);
  return isPRId(id) ? { kind: "pr", id } : null;
}

export function prTopic(id: string): string {
  return `pr:${id}`;
}

export function decodeHome(value: unknown): RemoteHome {
  const c = expectObject(value, "home");
  requireKeys(c.status, "status", "home.status");
  requireArray(c.prs, "pr", "home.prs");
  requireArray(c.ci, "ci", "home.ci");
  return c as unknown as RemoteHome;
}

export function decodePRDetail(value: unknown): RemotePRDetail {
  const c = expectObject(value, "pr detail");
  if (c.pr !== undefined) requireKeys(c.pr, "pr", "detail.pr");
  if (c.review !== undefined) requireKeys(c.review, "review", "detail.review");
  if (c.respond !== undefined) requireKeys(c.respond, "respond", "detail.respond");
  if (c.chat !== undefined) requireKeys(c.chat, "chat", "detail.chat");
  return c as RemotePRDetail;
}

export function decodeActivity(value: unknown): RemoteActivity {
  const c = expectObject(value, "activity");
  requireKeys(c.resources, "resources", "activity.resources");
  requireArray(c.history, "history", "activity.history");
  if (c.usage !== undefined) requireKeys(c.usage, "usage", "activity.usage");
  return c as unknown as RemoteActivity;
}

// --- Push y buzón (Sealed.swift) ---

/** Un estado guardado en el buzón del relay (Q.1): `data` son los bytes JSON del tópico. */
export interface MailboxBlob {
  slot: string;
  rev: number;
  createdAt: ISODate;
  data: Bytes;
}

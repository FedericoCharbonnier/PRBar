// Tipos de las props de cada pantalla (forma de view model: datos planos + callbacks). Las pantallas son puras: no
// hacen red ni guardan estado; el que las conecta (router + modelos) arma estos objetos.
import type { ComponentChildren } from "preact";

/** Persona (autor, revisor). `color` es el del avatar, determinístico por login (lo calcula `avatarColor`). */
export interface Person {
  name: string;
  login?: string | undefined;
  initials: string;
  color: string;
}

/** La Mac emparejada, para la píldora de arriba de Home/Activity y Settings. */
export interface MacInfo {
  name: string;
  online: boolean;
  /** "Connected · updated just now" / "Offline · last seen 8:12 AM". */
  detail: string;
}

// ---------- Home ----------

export type PRStateIcon = "feedback" | "ready" | "failing";
export type PRStatusKind = "agents" | "changes" | "approved" | "failed";

export interface PRStatusLine {
  /** agents = violeta `terminal`, changes = naranja, approved = verde, failed = rojo. */
  kind: PRStatusKind;
  text: string;
}

export type PRActionKind = "review" | "reviewing" | "comments" | "respond" | "merge" | "fixci";

export interface PRAction {
  kind: PRActionKind;
  /** "Review", "Reviewing…", "4 comments", "Respond", "Merge…", "Fix CI". */
  label: string;
}

export interface PRRowVM {
  id: string;
  title: string;
  /** Nombre corto del repo ("web-app"). */
  repo: string;
  number: number;
  /** Rama base que se muestra en la meta ("develop"). */
  branch: string;
  /** Edad relativa ya formateada ("8 min", "1h"). */
  age: string;
  additions: number;
  deletions: number;
  /** To Review: avatar del autor. My PRs: ícono de estado en un círculo teñido. */
  leading: { kind: "avatar"; person: Person } | { kind: "state"; state: PRStateIcon };
  status?: PRStatusLine | undefined;
  action?: PRAction | undefined;
  /** Sin conexión: todo en gris y la acción deshabilitada. */
  disabled?: boolean | undefined;
}

export interface PRSectionVM {
  id: string;
  title: string;
  count: number;
  collapsed: boolean;
  rows: PRRowVM[];
}

export interface OfflineCardVM {
  /** "Diego's MacBook Pro is offline or asleep". */
  title: string;
  /** "Last connected today at 8:12 AM. You're seeing cached data, and actions are off until your Mac is back." */
  message: string;
  retrying?: boolean | undefined;
}

export interface BannerVM {
  tone: "neutral" | "orange" | "red";
  icon?: "wifi.slash" | "clock" | "exclamationmark.triangle" | "checkmark.circle" | undefined;
  text: string;
  actionLabel?: string | undefined;
}

export interface HomeProps {
  mac: MacInfo;
  /** "To Review" (home) o "My PRs" (home:mine). */
  title: string;
  sections: PRSectionVM[];
  /** home:offline: tarjeta de Mac dormida arriba de las secciones (títulos y filas en gris). */
  offline?: OfflineCardVM | undefined;
  /** Aviso fino (datos viejos, sin red) arriba de la lista. */
  banner?: BannerVM | undefined;
  /** Actualizando (lo muestra el pull-to-refresh de la pantalla). */
  refreshing?: boolean | undefined;
  onOpen: (rowId: string) => void;
  onAction: (rowId: string) => void;
  onToggleSection: (sectionId: string) => void;
  onRetry?: (() => void) | undefined;
  onBannerAction?: (() => void) | undefined;
}

// ---------- Instalación y emparejamiento ----------

export interface InstallProps {
  /** iOS: los 3 pasos de Safari. Android/escritorio con `beforeinstallprompt`: botón "Install". */
  platform: "ios" | "android" | "other";
  canInstall?: boolean | undefined;
  onInstall?: (() => void) | undefined;
}

export interface PairWelcomeProps {
  deviceName: string;
  onDeviceNameChange: (name: string) => void;
  onPair: () => void;
  busy?: boolean | undefined;
  /** Error o aviso arriba del botón ("This device lost its pairing. Pair it again from your Mac."). */
  notice?: string | undefined;
  /** Abierto sobre una sesión que sigue andando (un link nuevo, o un emparejamiento que falló): volver a ella. */
  onCancel?: (() => void) | undefined;
}

export interface BootErrorProps {
  onRetry: () => void;
  /** Borra lo guardado y vuelve a pair:welcome (si el arranque llegó a abrir el almacenamiento). */
  onReset?: (() => void) | undefined;
}

export interface PasteCodeVM {
  value: string;
  error?: string | undefined;
  onChange: (value: string) => void;
  onSubmit: () => void;
  onCancel: () => void;
}

export interface PairScanProps {
  /** El `<video>` de la cámara (lo arma quien maneja getUserMedia + jsqr). Sin cámara se ve el fondo oscuro. */
  camera?: ComponentChildren;
  /** Mensaje bajo el subtítulo (permiso de cámara negado, QR inválido). */
  error?: string | undefined;
  onCancel: () => void;
  onPasteCode: () => void;
  /** Hoja para pegar el texto del QR. */
  paste?: PasteCodeVM | undefined;
}

export interface PairConfirmProps {
  macName: string;
  relayHost: string;
  /** Mac con la que ya está emparejado (se reemplaza). */
  replacing?: string | undefined;
  /** Uniéndose a la ranura de la Mac (el botón con spinner). */
  busy?: boolean | undefined;
  onConfirm: () => void;
  onCancel: () => void;
}

export interface PairSasProps {
  macName: string;
  /** Seis dígitos ("482913"); se muestran 3 + 3. */
  code: string;
  onMismatch?: (() => void) | undefined;
}

export type NotificationPermission = "default" | "granted" | "denied" | "unsupported";

export interface PairPairedProps {
  macName: string;
  notifications: NotificationPermission;
  busy?: boolean | undefined;
  onAllowNotifications: () => void;
  onContinue: () => void;
}

// ---------- Detalle de PR (común) ----------

export interface PRHeaderVM {
  /** "acme/api". */
  repoFull: string;
  number: number;
  title: string;
}

export type Severity = "high" | "medium" | "low";

/** Botón para arrancar a Claude cuando todavía no hay nada ("Review with Claude", "Respond with Claude"). */
export interface StartVM {
  label: string;
  onClick: () => void;
  busy?: boolean | undefined;
  disabled?: boolean | undefined;
}

// ---------- Review ----------

export type ReviewDecision = "comment" | "request_changes" | "approve";

export interface FindingVM {
  id: string;
  severity: Severity;
  /** "src/auth/session.ts:88". */
  location: string;
  title: string;
  text: string;
  included: boolean;
}

export interface ReviewProps {
  pr: PRHeaderVM & {
    author: Person;
    age: string;
    additions: number;
    deletions: number;
    head: string;
    base: string;
    files: number;
  };
  summary: { text: string; meta: string };
  findings: FindingVM[];
  decision: ReviewDecision;
  /** review:menu. */
  menuOpen?: boolean | undefined;
  /** review:faceid — esperando el aviso del sistema. */
  faceIdPending?: boolean | undefined;
  posting?: boolean | undefined;
  /** Post pide Face ID con la decisión elegida (ícono `faceid`); por defecto sí. Sin Face ID, el modelo confirma. */
  postFaceId?: boolean | undefined;
  disabled?: boolean | undefined;
  /** Sin review todavía: el botón "Review with Claude" en lugar del resumen y los hallazgos ("Try Again" si falló). */
  start?: StartVM | undefined;
  /** El review falló: el motivo, en rojo arriba del botón. */
  error?: string | undefined;
  onBack: () => void;
  onChat: () => void;
  onMore: () => void;
  onToggleFinding: (id: string, included: boolean) => void;
  onEditFinding: (id: string) => void;
  onOpenDecisionMenu: () => void;
  onCloseDecisionMenu: () => void;
  onSelectDecision: (decision: ReviewDecision) => void;
  onPost: () => void;
}

export interface ReviewPostedProps {
  decision: ReviewDecision;
  /** "Approved api#317 with 3 comments.". */
  message: string;
  inlineComments: number;
  postedFrom: string;
  onViewOnGitHub: () => void;
  onDone: () => void;
}

export interface CodeLineVM {
  number: number;
  text: string;
  highlight?: boolean | undefined;
}

export interface EditProps {
  /** "Finding 1 of 4". */
  subtitle: string;
  severity: Severity;
  location: string;
  /** Extracto opcional del código alrededor de la línea comentada. */
  excerpt?: CodeLineVM[] | undefined;
  text: string;
  line: number;
  saving?: boolean | undefined;
  onChange: (text: string) => void;
  onSave: () => void;
  onDiscard: () => void;
}

// ---------- Respond / Fix CI / Diff ----------

export type StageState = "done" | "current" | "pending";

export interface StageVM {
  label: string;
  state: StageState;
  /** Tiempo de la etapa ("0:42"), opcional. */
  time?: string | undefined;
  /** Línea mono debajo ("Editing src/reports/export.ts", "142 passed"). */
  detail?: string | undefined;
}

export interface ProgressVM {
  /** "Claude is fixing 2 comments" (corriendo) / "Fixed · tests passing" (listo). */
  title: string;
  done: boolean;
  /** "2:30" / "10:52:03". */
  elapsed: string;
  stages: StageVM[];
}

export interface StatusVM {
  kind: "changes" | "failed" | "passing";
  text: string;
}

export interface FeedbackCommentVM {
  id: string;
  author: Person;
  age?: string | undefined;
  location: string;
  text: string;
  selected: boolean;
}

export interface CheckLogLine {
  text: string;
  tone: "error" | "detail" | "plain";
}

export interface FailedCheckVM {
  id: string;
  name: string;
  duration: string;
  log: CheckLogLine[];
}

export interface ChangedFileVM {
  id: string;
  path: string;
  additions: number;
  deletions: number;
}

export interface RespondBaseProps {
  pr: PRHeaderVM;
  status: StatusVM;
  progress?: ProgressVM | undefined;
  /** Mientras Claude trabaja: Stop + primario deshabilitado. Al terminar: Undo + primario activo. */
  running: boolean;
  disabled?: boolean | undefined;
  faceIdPending?: boolean | undefined;
  /** Sin respuesta todavía: "Respond with Claude" / "Fix CI with Claude" en lugar del progreso y la lista. */
  start?: StartVM | undefined;
  /** Arriba del progreso: por qué no se pusheó (los checks pasan ahora, fallaron los tests) o por qué falló. */
  banner?: BannerVM | undefined;
  onBannerAction?: (() => void) | undefined;
  /** El título si no es el de la pantalla ("Resolve Conflicts" en la pantalla de Respond). */
  title?: string | undefined;
  /** Texto del primario si no es el de la pantalla ("Implement", "Reply", "Push Anyway", "Push from your Mac"). */
  primaryLabel?: string | undefined;
  /** El primario pide Face ID (ícono `faceid`); por defecto sí. */
  primaryFaceId?: boolean | undefined;
  /** "Tests" pide Face ID; por defecto sí. */
  testsFaceId?: boolean | undefined;
  primaryDisabled?: boolean | undefined;
  /** Sin Stop ni Undo (antes de implementar). */
  secondaryHidden?: boolean | undefined;
  /** "Tests" (corre los tests en la Mac, con Face ID) cuando los arreglos están listos. */
  onRunTests?: (() => void) | undefined;
  onBack: () => void;
  onChat: () => void;
  onStop: () => void;
  onUndo: () => void;
  onPrimary: () => void;
}

export interface RespondProps extends RespondBaseProps {
  comments: FeedbackCommentVM[];
  /** Resumen del diff cuando terminó ("2 files changed, 15 insertions(+), 4 deletions(-)"). */
  changesSummary?: string | undefined;
  onToggleComment: (id: string, selected: boolean) => void;
  onOpenChanges: () => void;
}

export interface FixCIProps extends RespondBaseProps {
  /** "2 of 9". */
  failedLabel: string;
  checks: FailedCheckVM[];
  /** Archivos cambiados al terminar. */
  files?: ChangedFileVM[] | undefined;
  onOpenFile: (id: string) => void;
}

export type DiffLineKind = "hunk" | "context" | "add" | "del";

export interface DiffLineVM {
  kind: DiffLineKind;
  number?: number | undefined;
  text: string;
}

export interface DiffFileVM extends ChangedFileVM {
  /** Nombre corto para el chip ("export.ts"). */
  name: string;
  lines: DiffLineVM[];
}

export interface RespondDiffProps extends RespondBaseProps {
  /** "Changes". */
  files: DiffFileVM[];
  selectedFileId: string;
  reply?: { to: string; text: string } | undefined;
  /** "Push & Reply" (respond) o "Push" (fix CI). */
  primaryLabel: string;
  onSelectFile: (id: string) => void;
}

// ---------- Merge ----------

export type MergeMethod = "squash" | "merge" | "rebase";

export interface MergeProps {
  pr: PRHeaderVM & { head: string; base: string; additions: number; deletions: number };
  description: string;
  reviewers: { person: Person; state: string; tone: "green" | "orange" | "neutral" }[];
  /** "9 passing". */
  checks: { text: string; tone: "green" | "red" | "neutral" };
  /** "None". */
  unresolved: string;
  /** "4 changed". */
  files: string;
  method: MergeMethod;
  /** Nota bajo el selector, por método. */
  methodNotes: Record<MergeMethod, string>;
  merging?: boolean | undefined;
  /** merge:faceid. */
  faceIdPending?: boolean | undefined;
  /** Merge pide Face ID (ícono `faceid`); por defecto sí. Sin Face ID, el modelo confirma. */
  mergeFaceId?: boolean | undefined;
  disabled?: boolean | undefined;
  onBack: () => void;
  onChat: () => void;
  onFiles: () => void;
  onMethod: (method: MergeMethod) => void;
  onMerge: () => void;
}

export interface MergedProps {
  /** "api#322 was squashed into main.". */
  message: string;
  /** "Posted in #api-reviews". */
  postedIn?: string | undefined;
  onClose: () => void;
  onChat: () => void;
  onViewOnGitHub: () => void;
  onDone: () => void;
}

// ---------- Chat ----------

export type ChatItemVM =
  | { kind: "mine"; id: string; text: string }
  | { kind: "claude"; id: string; text: string }
  | { kind: "action"; id: string; title: string; detail: string; undoable: boolean };

export interface ChatProps {
  /** "api#317 · Review". */
  context: string;
  /** chat:merge: solo preguntas. */
  readOnly: boolean;
  /** "Today 9:32 AM". */
  timestamp?: string | undefined;
  items: ChatItemVM[];
  typing?: boolean | undefined;
  draft: string;
  /** "Message Claude" / "Ask about this PR". */
  placeholder: string;
  disabled?: boolean | undefined;
  /** Claude está contestando: el botón de enviar pasa a ser Stop. */
  running?: boolean | undefined;
  onBack: () => void;
  onDraft: (text: string) => void;
  onSend: () => void;
  onStop?: (() => void) | undefined;
  onUndo: (id: string) => void;
}

// ---------- Activity ----------

export interface StatTileVM {
  icon: "cpu" | "memorychip" | "internaldrive";
  label: string;
  value: string;
  sub: string;
  /** 0…1. */
  fraction: number;
  tone: "green" | "orange" | "accent" | "red";
}

export interface RunningTaskVM {
  id: string;
  title: string;
  sub: string;
}

export interface SpendSegmentVM {
  label: string;
  /** "31", "46 msgs". */
  count: string;
  amount: string;
  value: number;
  tone: "violet" | "accent" | "neutral";
}

export interface ActivityProps {
  mac: MacInfo;
  stats: StatTileVM[];
  running: RunningTaskVM[];
  month: { total: string; caption: string; segments: SpendSegmentVM[] };
  onStop: (id: string) => void;
}

// ---------- Settings ----------

export interface ToggleRowVM {
  id: string;
  label: string;
  on: boolean;
  disabled?: boolean | undefined;
}

export interface SettingsProps {
  mac: MacInfo & { secure: string };
  notifications: ToggleRowVM[];
  requireFaceId: ToggleRowVM;
  /** Sección CLAUDE (Repositories, Claude rules), opcional. */
  claude?: { id: string; label: string; value: string }[] | undefined;
  version: string;
  onUnpair: () => void;
  onToggleNotification: (id: string, on: boolean) => void;
  onToggleFaceId: (on: boolean) => void;
  onOpenClaude?: ((id: string) => void) | undefined;
}

// ---------- Tab bar ----------

export type TabId = "review" | "mine" | "activity" | "settings";

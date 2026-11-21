import { useEffect, useMemo, useState } from "preact/hooks";
import type { AppContext } from "../app/context";
import type { InstallPromptEvent, Platform } from "../app/install";
import { createChatModel } from "../app/models/chat";
import { defaultScreen, type HomeModel, type HomeTab } from "../app/models/home";
import { createMergeModel } from "../app/models/merge";
import type { PairingModel } from "../app/models/pairing";
import { createRespondModel, type RespondMode } from "../app/models/respond";
import { createReviewModel } from "../app/models/review";
import type { ChatKind, PRScreenId } from "../app/router";
import type { Active, Shell } from "../app/shell";
import { Camera } from "./Camera";
import { ActionMenu, Banner, Button, Sheet, TabBar } from "./components";
import {
  Activity, Chat, Edit, FixCI, Home, Install, Merge, Merged, PairConfirm, PairPaired, PairSas, PairScan, PairWelcome,
  Respond, RespondDiff, Review, ReviewPosted, Settings,
} from "./screens";
import "./app.css";

// La app: la pantalla `install` fuera de la pantalla de inicio; adentro, el emparejamiento o las cuatro pestañas con
// sus pantallas de detalle, y encima los avisos, confirmaciones y menús del shell.

export function InstallGate({ platform, prompt }: { platform: Platform; prompt: () => InstallPromptEvent | null }) {
  const [event, setEvent] = useState<InstallPromptEvent | null>(prompt);
  useEffect(() => {
    const on = (e: Event) => {
      e.preventDefault();
      setEvent(e as InstallPromptEvent);
    };
    addEventListener("beforeinstallprompt", on);
    return () => removeEventListener("beforeinstallprompt", on);
  }, []);
  return (
    <Install
      platform={platform}
      canInstall={!!event}
      onInstall={() => {
        void event?.prompt().catch(() => {});
        setEvent(null);
      }}
    />
  );
}

export function App({ shell }: { shell: Shell }) {
  if (!shell.ready.value) return <div class="boot" aria-busy="true" />;
  const active = shell.active.value;
  const step = shell.pairing.step.value.kind;
  const pairing = !active || shell.pairingOpen.value || step === "paired";
  return (
    <>
      {pairing ? <PairingFlow shell={shell} model={shell.pairing} /> : <Paired shell={shell} active={active} />}
      <Overlays shell={shell} />
    </>
  );
}

// ---------- Emparejamiento ----------

function PairingFlow({ shell, model }: { shell: Shell; model: PairingModel }) {
  const step = model.step.value;
  const cancel = () => {
    if (step.kind === "confirm") model.cancelConfirm();
    else model.cancelScanning();
    shell.closePairing();
  };
  switch (step.kind) {
    case "welcome":
      return (
        <PairWelcome
          deviceName={model.deviceName.value}
          notice={model.notice.value ?? undefined}
          busy={model.busy.value}
          onDeviceNameChange={(name) => model.setDeviceName(name)}
          onPair={() => void model.pair()}
        />
      );
    case "scanning":
      return (
        <PairScan
          camera={step.paste ? undefined : <Camera onScan={(text) => model.scanned(text)} onError={() => model.cameraFailed()} />}
          error={model.scanError.value ?? undefined}
          onCancel={cancel}
          onPasteCode={() => model.openPaste()}
          paste={step.paste ? {
            value: step.paste.value, error: step.paste.error,
            onChange: (value) => model.setPaste(value), onSubmit: () => model.submitPaste(), onCancel: () => model.closePaste(),
          } : undefined}
        />
      );
    case "confirm":
      return (
        <PairConfirm
          macName={step.qr.macName}
          relayHost={step.qr.relayHost}
          replacing={step.replacing ?? undefined}
          busy={step.busy}
          onConfirm={() => void model.confirm()}
          onCancel={cancel}
        />
      );
    case "sas":
      return <PairSas macName={step.macName} code={step.code} onMismatch={() => model.mismatch()} />;
    case "paired":
      return (
        <PairPaired
          macName={step.macName}
          notifications={step.notifications}
          busy={step.busy}
          onAllowNotifications={() => void model.allowNotifications()}
          onContinue={() => model.done()}
        />
      );
  }
}

// ---------- Emparejado ----------

function Paired({ shell, active }: { shell: Shell; active: Active }) {
  const route = shell.router.route.value;
  const { ctx } = active;
  if (route.kind === "pr") {
    const screen = route.screen ?? defaultScreen(ctx.store, route.pr) ?? "review";
    return <PRScreen key={`${route.pr}|${screen}|${route.chat ?? ""}`} ctx={ctx} pr={route.pr} screen={screen} chat={route.chat} />;
  }
  const tab = route.kind === "tab" ? route.tab : "review";
  return (
    <div class="app--tabs">
      {tab === "review" || tab === "mine" ? <HomeScreen model={active.home} tab={tab} /> : null}
      {tab === "activity" ? <ActivityScreen active={active} /> : null}
      {tab === "settings" ? <SettingsScreen active={active} /> : null}
      <TabBar selected={tab} reviewBadge={active.home.badge.value} onSelect={(t) => shell.router.tab(t)} />
    </div>
  );
}

/** Tirar hacia abajo desde arriba de todo: `refresh` (o reintentar sin conexión). */
function usePullToRefresh(onRefresh: () => void) {
  useEffect(() => {
    let start: number | null = null;
    let pulled = 0;
    const down = (e: TouchEvent) => {
      start = scrollY <= 0 && e.touches.length === 1 ? e.touches[0]!.clientY : null;
      pulled = 0;
    };
    const move = (e: TouchEvent) => {
      if (start !== null) pulled = e.touches[0]!.clientY - start;
    };
    const up = () => {
      if (start !== null && pulled > 80) onRefresh();
      start = null;
    };
    addEventListener("touchstart", down, { passive: true });
    addEventListener("touchmove", move, { passive: true });
    addEventListener("touchend", up);
    return () => {
      removeEventListener("touchstart", down);
      removeEventListener("touchmove", move);
      removeEventListener("touchend", up);
    };
  }, [onRefresh]);
}

function HomeScreen({ model, tab }: { model: HomeModel; tab: HomeTab }) {
  usePullToRefresh(useMemo(() => () => void model.refresh(), [model]));
  return <Home {...model.props(tab)} />;
}

function ActivityScreen({ active }: { active: Active }) {
  useEffect(() => active.activity.open(), [active]);
  return <Activity {...active.activity.props.value} />;
}

function SettingsScreen({ active }: { active: Active }) {
  const stale = active.ctx.store.isStale.value;
  useEffect(() => {
    if (!stale) void active.settings.load();
  }, [active, stale]);
  return <Settings {...active.settings.props.value} />;
}

function PRScreen({ ctx, pr, screen, chat }: { ctx: AppContext; pr: string; screen: PRScreenId; chat?: ChatKind | undefined }) {
  switch (screen) {
    case "review":
      return <ReviewScreen ctx={ctx} pr={pr} />;
    case "respond":
    case "fixci":
    case "diff":
      return <RespondScreen ctx={ctx} pr={pr} screen={screen} />;
    case "merge":
      return <MergeScreen ctx={ctx} pr={pr} />;
    case "chat":
      return <ChatScreen ctx={ctx} pr={pr} kind={chat ?? (ctx.store.isMine(pr) ? "respond" : "review")} />;
  }
}

function ReviewScreen({ ctx, pr }: { ctx: AppContext; pr: string }) {
  const model = useMemo(() => createReviewModel(ctx, pr), [ctx, pr]);
  useEffect(() => model.open(), [model]);
  const view = model.view.value;
  if (view.kind === "posted") return <ReviewPosted {...view.props} />;
  return (
    <>
      <Review {...view.props} />
      {view.edit && <Edit {...view.edit} />}
    </>
  );
}

function RespondScreen({ ctx, pr, screen }: { ctx: AppContext; pr: string; screen: "respond" | "fixci" | "diff" }) {
  const fallback: RespondMode = screen === "fixci" || ctx.store.home.value?.ci.some((c) => c.pr === pr) ? "ciFix" : "feedback";
  const model = useMemo(() => createRespondModel(ctx, pr, fallback), [ctx, pr]);
  useEffect(() => model.open(), [model]);
  const view = model.view(screen === "diff" ? "diff" : "main");
  const done = !!view.props.progress?.done;
  useEffect(() => {
    // Los cambios: en respond:diff siempre; en Fix CI, la lista de archivos cuando terminó.
    if (screen === "diff" || (view.kind === "fixci" && done)) void model.loadDiff();
  }, [model, screen, view.kind, done]);
  switch (view.kind) {
    case "respond":
      return <Respond {...view.props} />;
    case "fixci":
      return <FixCI {...view.props} />;
    case "diff":
      return <RespondDiff {...view.props} />;
  }
}

function MergeScreen({ ctx, pr }: { ctx: AppContext; pr: string }) {
  const model = useMemo(() => createMergeModel(ctx, pr), [ctx, pr]);
  useEffect(() => model.open(), [model]);
  const view = model.view.value;
  return view.kind === "merged" ? <Merged {...view.props} /> : <Merge {...view.props} />;
}

function ChatScreen({ ctx, pr, kind }: { ctx: AppContext; pr: string; kind: ChatKind }) {
  const model = useMemo(() => createChatModel(ctx, pr, kind), [ctx, pr, kind]);
  useEffect(() => model.open(), [model]);
  return <Chat {...model.props.value} />;
}

// ---------- Avisos ----------

function Overlays({ shell }: { shell: Shell }) {
  const { ui } = shell;
  const alerts = ui.alerts.value;
  const confirmation = ui.confirmation.value;
  const menu = ui.openMenu.value;
  return (
    <>
      {alerts.length > 0 && (
        <div class="app-alerts" role="alert">
          {alerts.map((a) => (
            <button key={a.id} type="button" class="app-alerts__item" onClick={() => ui.dismissAlert(a.id)}>
              <Banner banner={{ tone: "red", icon: "exclamationmark.triangle", text: a.message }} />
            </button>
          ))}
        </div>
      )}
      {confirmation && (
        <Sheet detent="medium" label={confirmation.title} onDismiss={() => confirmation.resolve(false)}>
          <div class="app-confirm">
            <h2>{confirmation.title}</h2>
            {confirmation.message && <p>{confirmation.message}</p>}
            <Button variant={confirmation.destructive ? "destructive" : "filled"} size="lg" block onClick={() => confirmation.resolve(true)}>
              {confirmation.confirmLabel}
            </Button>
            <Button variant="plain" size="lg" block onClick={() => confirmation.resolve(false)}>
              {confirmation.cancelLabel}
            </Button>
          </div>
        </Sheet>
      )}
      {menu && (
        <ActionMenu items={menu.items} label={menu.label} anchor="top-end" onSelect={(id) => menu.resolve(id)} onDismiss={() => menu.resolve(null)} />
      )}
    </>
  );
}

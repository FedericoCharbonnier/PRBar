import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import type { AppContext } from "../app/context";
import type { InstallPromptEvent, Platform } from "../app/install";
import { createChatModel } from "../app/models/chat";
import { defaultScreen, type HomeModel, type HomeTab } from "../app/models/home";
import { createMergeModel } from "../app/models/merge";
import type { PairingModel } from "../app/models/pairing";
import { createRespondModel, type RespondMode } from "../app/models/respond";
import { createReviewModel } from "../app/models/review";
import { routeTitle, type StackRoute } from "../app/navstack";
import type { ChatKind, PRScreenId } from "../app/router";
import type { Active, Shell } from "../app/shell";
import { Camera } from "./Camera";
import { ActionMenu, Banner, Button, Sheet, TabBar } from "./components";
import {
  Activity, BootError, Chat, Edit, FixCI, Home, Install, Merge, Merged, PairConfirm, PairPaired, PairSas, PairScan, PairWelcome,
  Respond, RespondDiff, Review, ReviewPosted, Settings,
} from "./screens";
import { ghost, reducedMotion } from "./motion/animate";
import { NavHost, SoloPage } from "./nav/NavHost";
import { PullToRefresh } from "./nav/PullToRefresh";
import type { TabId } from "./screens/types";
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
  if (shell.bootFailed.value) {
    return <BootError onRetry={() => location.reload()} onReset={() => void shell.resetAfterBootFailure()} />;
  }
  const active = shell.active.value;
  const step = shell.pairing.step.value.kind;
  const pairing = !active || shell.pairingOpen.value || step === "paired";
  return (
    <>
      {pairing ? (
        <SoloPage id={`pair:${step}`}>
          <PairingFlow shell={shell} model={shell.pairing} />
        </SoloPage>
      ) : (
        <Paired shell={shell} active={active} />
      )}
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
          onCancel={shell.active.value ? () => shell.closePairing() : undefined}
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
  const { router } = shell;
  const nav = router.nav.value;
  const { ctx } = active;
  // Las pestañas se montan la primera vez que se eligen y después quedan (con su pila y su scroll).
  const visited = useRef<TabId[]>([]);
  if (!visited.current.includes(nav.state.tab)) visited.current = [...visited.current, nav.state.tab];
  const select = (tab: TabId) => {
    const state = router.nav.peek().state;
    if (tab === state.tab && state.stacks[tab].length === 1) {
      // Tocar la pestaña elegida en su raíz: arriba de todo.
      const scroller = document.querySelector(".stack--active .page--root .page__scroll");
      scroller?.scrollTo({ top: 0, behavior: reducedMotion() ? "auto" : "smooth" });
      return;
    }
    router.tab(tab);
  };
  const screenOf = (route: StackRoute & { kind: "pr" }) => route.screen ?? defaultScreen(ctx.store, route.pr) ?? "review";
  return (
    <NavHost
      nav={nav}
      tabs={visited.current}
      titleOf={(route) => routeTitle(route, route.kind === "pr" ? screenOf(route) : undefined)}
      onBack={() => router.back()}
      renderRoute={(route, { visible }) => {
        if (route.kind === "tab") {
          return (
            <>
              <TabRoot active={active} tab={route.tab} visible={visible} />
              <TabBar selected={route.tab} reviewBadge={active.home.badge.value} onSelect={select} />
            </>
          );
        }
        const screen = screenOf(route);
        return (
          <PRScreen key={`${route.pr}|${screen}|${route.chat ?? ""}|${route.file ?? ""}`} ctx={ctx} pr={route.pr} screen={screen}
                    chat={route.chat} file={route.file} />
        );
      }}
    />
  );
}

function TabRoot({ active, tab, visible }: { active: Active; tab: TabId; visible: boolean }) {
  switch (tab) {
    case "review":
    case "mine":
      return <HomeScreen model={active.home} tab={tab} />;
    case "activity":
      return <ActivityScreen active={active} visible={visible} />;
    case "settings":
      return <SettingsScreen active={active} visible={visible} />;
  }
}

function HomeScreen({ model, tab }: { model: HomeModel; tab: HomeTab }) {
  const props = model.props(tab);
  const refresh = useMemo(() => () => void model.refresh(), [model]);
  return (
    <>
      <PullToRefresh refreshing={!!props.refreshing} onRefresh={refresh} />
      <Home {...props} />
    </>
  );
}

function ActivityScreen({ active, visible }: { active: Active; visible: boolean }) {
  // Las estadísticas de la Mac se piden solo mientras la pestaña está a la vista.
  useEffect(() => (visible ? active.activity.open() : undefined), [active, visible]);
  return <Activity {...active.activity.props.value} />;
}

function SettingsScreen({ active, visible }: { active: Active; visible: boolean }) {
  const stale = active.ctx.store.isStale.value;
  useEffect(() => {
    if (!stale && visible) void active.settings.load();
  }, [active, stale, visible]);
  return <Settings {...active.settings.props.value} />;
}

function PRScreen({ ctx, pr, screen, chat, file }: {
  ctx: AppContext; pr: string; screen: PRScreenId; chat?: ChatKind | undefined; file?: string | undefined;
}) {
  switch (screen) {
    case "review":
      return <ReviewScreen ctx={ctx} pr={pr} />;
    case "respond":
    case "fixci":
    case "diff":
      return <RespondScreen ctx={ctx} pr={pr} screen={screen} file={file} />;
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

function RespondScreen({ ctx, pr, screen, file }: {
  ctx: AppContext; pr: string; screen: "respond" | "fixci" | "diff"; file?: string | undefined;
}) {
  const fallback: RespondMode = screen === "fixci" || ctx.store.home.value?.ci.some((c) => c.pr === pr) ? "ciFix" : "feedback";
  const model = useMemo(() => createRespondModel(ctx, pr, fallback, file), [ctx, pr]);
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

/** Un aviso: baja desde arriba al aparecer (CSS) y sube al irse. */
function AlertItem({ message, onDismiss }: { message: string; onDismiss: () => void }) {
  const ref = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    return () => ghost(el, () => (reducedMotion()
      ? [{ opacity: 1 }, { opacity: 0 }]
      : [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translate3d(0, -110%, 0)" }]), { duration: 280, easing: "ease-in" });
  }, []);
  return (
    <button ref={ref} type="button" class="app-alerts__item" onClick={onDismiss}>
      <Banner banner={{ tone: "red", icon: "exclamationmark.triangle", text: message }} />
    </button>
  );
}

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
            <AlertItem key={a.id} message={a.message} onDismiss={() => ui.dismissAlert(a.id)} />
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

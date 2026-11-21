import type { ComponentChildren } from "preact";
import { AppTile, Button, Card, GlassButton, HeroCircle, Icon, ListRow, SASCode, Screen, Sheet, Spinner } from "../components";
import type { IconName } from "../components";
import type { InstallProps, PairConfirmProps, PairPairedProps, PairSasProps, PairScanProps, PairWelcomeProps } from "./types";
import "./screens.css";

// Instalación y emparejamiento: install, pair:welcome, pair:scan, pair:confirm, pair:sas, pair:paired.

function Feature({ icon, title, text }: { icon: IconName; title: string; text: ComponentChildren }) {
  return (
    <li class="feature">
      <Icon name={icon} size={28} class="feature__icon" />
      <span>
        <strong>{title}</strong>
        <span>{text}</span>
      </span>
    </li>
  );
}

/** Página abierta en Safari sin instalar: ícono + "Add PRBar to your Home Screen" + 3 pasos (estilo pair:welcome). */
export function Install({ platform, canInstall, onInstall }: InstallProps) {
  return (
    <Screen variant="plain" class="onboard" label="Install PRBar">
      <div class="onboard__body">
        <AppTile size={100} glow />
        <h1 class="onboard__title">Add PRBar to your Home Screen</h1>
        <p class="onboard__lead">PRBar runs from your Home Screen, like an app. Pairing and notifications work only there.</p>
        {platform === "ios" ? (
          <ol class="features features--steps">
            <Feature icon="square.and.arrow.up" title="Tap Share" text={<>In Safari’s toolbar, tap the Share button.</>} />
            <Feature icon="plus.app" title="Add to Home Screen" text="Scroll down the list and tap Add to Home Screen, then Add." />
            <Feature icon="hand.tap" title="Open PRBar from the icon" text="Then pair it with your Mac from there." />
          </ol>
        ) : (
          <ol class="features features--steps">
            <Feature icon="plus.app" title="Install the app" text="Add PRBar to your home screen or dock." />
            <Feature icon="hand.tap" title="Open PRBar from the icon" text="Then pair it with your Mac from there." />
          </ol>
        )}
      </div>
      {platform !== "ios" && canInstall && (
        <div class="onboard__footer">
          <Button size="xl" block icon="plus.app" onClick={onInstall}>
            Install
          </Button>
        </div>
      )}
    </Screen>
  );
}

export function PairWelcome({ deviceName, onDeviceNameChange, onPair, busy, notice }: PairWelcomeProps) {
  return (
    <Screen variant="plain" class="onboard" label="Welcome to PRBar">
      <div class="onboard__body">
        <AppTile size={100} glow />
        <h1 class="onboard__title">Welcome to PRBar</h1>
        <p class="onboard__lead">Your Mac does the work. Your iPhone is the remote.</p>
        <ul class="features">
          <Feature icon="bolt.fill" title="Live from your Mac" text="Reviews, CI and Claude's progress as they happen." />
          <Feature icon="checkmark.circle" title="Act from anywhere" text="Review, respond, fix CI and merge with a tap." />
          <Feature
            icon="lock.shield"
            title="End-to-end encrypted"
            text="Your iPhone reaches your Mac through a relay that can’t read your data."
          />
        </ul>
      </div>
      <div class="onboard__footer">
        {notice && (
          <p class="onboard__notice" role="alert">
            <Icon name="exclamationmark.triangle.fill" size={16} />
            {notice}
          </p>
        )}
        <label class="field">
          <span class="field__label">Device name</span>
          <input
            class="field__input"
            type="text"
            value={deviceName}
            maxLength={40}
            autoComplete="off"
            spellcheck={false}
            onInput={(e) => onDeviceNameChange((e.currentTarget as HTMLInputElement).value)}
          />
        </label>
        <Button size="xl" block icon="qrcode.viewfinder" busy={busy} disabled={!deviceName.trim()} onClick={onPair}>
          Scan QR on your Mac
        </Button>
        <p class="onboard__caption">On your Mac, open PRBar › Settings › Pair iPhone.</p>
      </div>
    </Screen>
  );
}

export function PairScan({ camera, error, onCancel, onPasteCode, paste }: PairScanProps) {
  return (
    <Screen variant="dark" class="scan" label="Scan the QR code">
      <div class="scan__camera">{camera}</div>
      <div class="scan__top">
        <GlassButton icon="xmark" label="Cancel" onClick={onCancel} iconSize={22} />
      </div>
      <h1 class="scan__title">Scan the QR code</h1>
      <p class="scan__sub">It's in PRBar › Settings › Pair iPhone on your Mac.</p>
      {error && (
        <p class="scan__error" role="alert">
          {error}
        </p>
      )}
      <svg class="scan__finder" viewBox="0 0 265 265" aria-hidden="true">
        <path d="M2.5 58V28.5a26 26 0 0 1 26-26H58M207 2.5h29.5a26 26 0 0 1 26 26V58M262.5 207v29.5a26 26 0 0 1-26 26H207M58 262.5H28.5a26 26 0 0 1-26-26V207" />
      </svg>
      <div class="scan__bottom">
        <button type="button" class="scan__paste" onClick={onPasteCode}>
          <Icon name="doc.on.clipboard" size={17} />
          Paste code
        </button>
        <span class="scan__chip">
          <Icon name="lock.fill" size={14} />
          End-to-end encrypted pairing
        </span>
      </div>
      {paste && (
        <Sheet detent="medium" label="Paste code" onDismiss={paste.onCancel}>
          <div class="paste">
            <div class="paste__head">
              <Button variant="glass" size="md" onClick={paste.onCancel}>
                Cancel
              </Button>
              <h2>Paste code</h2>
              <Button size="md" disabled={!paste.value.trim()} onClick={paste.onSubmit}>
                Pair
              </Button>
            </div>
            <p class="paste__hint">Paste the pairing link that `prbar remote pair` prints on your Mac.</p>
            <textarea
              class="paste__input"
              value={paste.value}
              rows={4}
              spellcheck={false}
              autoComplete="off"
              aria-label="Pairing code"
              onInput={(e) => paste.onChange((e.currentTarget as HTMLTextAreaElement).value)}
            />
            {paste.error && (
              <p class="paste__error" role="alert">
                {paste.error}
              </p>
            )}
          </div>
        </Sheet>
      )}
    </Screen>
  );
}

/** pair:confirm — antes del handshake: a qué Mac y relay se va a emparejar. */
export function PairConfirm({ macName, relayHost, replacing, busy, onConfirm, onCancel }: PairConfirmProps) {
  return (
    <Screen variant="plain" class="onboard onboard--center" label={`Pair with ${macName}?`}>
      <div class="onboard__body onboard__body--center">
        <HeroCircle icon="laptopcomputer" tone="fill" size={88} iconSize={60} />
        <h1 class="result__title result__title--pair">Pair with {macName}?</h1>
        <div class="confirm-card">
          <ListRow label="Mac" value={macName} />
          <ListRow label="Relay" value={relayHost} />
        </div>
        {replacing && (
          <p class="warn-card">
            <Icon name="exclamationmark.triangle.fill" size={20} />
            This replaces your pairing with {replacing}.
          </p>
        )}
        <p class="onboard__fine">
          Only continue if you just opened Pair iPhone on your Mac. You'll compare a 6-digit code next.
        </p>
      </div>
      <div class="onboard__footer">
        <Button size="xl" block busy={busy} onClick={onConfirm}>
          {replacing ? "Replace and Pair" : "Pair"}
        </Button>
        <Button variant="plain" size="lg" block onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </Screen>
  );
}

/** pair:sas — el código de 6 dígitos; se confirma en la Mac. */
export function PairSas({ macName, code, onMismatch }: PairSasProps) {
  return (
    <Screen variant="plain" class="onboard onboard--center" label="Confirm on your Mac">
      <div class="onboard__body onboard__body--center">
        <HeroCircle icon="laptopcomputer" tone="fill" size={88} iconSize={60} />
        <h1 class="result__title result__title--pair">Confirm on your Mac</h1>
        <p class="result__text">Check that this code matches the one on {macName}, then confirm there.</p>
        <SASCode code={code} />
        <p class="sas-note">
          <Icon name="lock.fill" size={14} />
          Connected through an encrypted relay
        </p>
        <p class="sas-wait" role="status">
          <Spinner size={16} />
          Waiting for your Mac…
        </p>
      </div>
      {onMismatch && (
        <div class="onboard__footer">
          <Button variant="destructive" size="lg" block onClick={onMismatch}>
            Codes Don't Match
          </Button>
        </div>
      )}
    </Screen>
  );
}

/** pair:paired — listo; pide permiso de notificaciones (iOS exige un gesto). */
export function PairPaired({ macName, notifications, busy, onAllowNotifications, onContinue }: PairPairedProps) {
  const asked = notifications === "granted" || notifications === "denied" || notifications === "unsupported";
  return (
    <Screen variant="plain" class="onboard onboard--center" label={`Paired with ${macName}`}>
      <div class="onboard__body onboard__body--center">
        <HeroCircle icon="checkmark" tone="green" size={88} iconSize={46} />
        <h1 class="result__title result__title--pair">Paired with {macName}</h1>
        <p class="result__text">
          {notifications === "granted"
            ? "Notifications are on. You'll hear when a review is ready."
            : notifications === "denied"
              ? "Notifications are off. You can turn them on in Settings."
              : "Turn on notifications to hear when a review is ready or CI fails."}
        </p>
        <p class="sas-note">
          <Icon name="lock.fill" size={14} />
          Connected through an encrypted relay
        </p>
      </div>
      <div class="onboard__footer">
        {!asked && (
          <Button size="xl" block icon="bell" busy={busy} onClick={onAllowNotifications}>
            Allow notifications
          </Button>
        )}
        <Button variant={asked ? "filled" : "plain"} size={asked ? "xl" : "lg"} block onClick={onContinue}>
          {asked ? "Continue" : "Not Now"}
        </Button>
      </div>
    </Screen>
  );
}

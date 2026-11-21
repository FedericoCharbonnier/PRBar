import { AppTile, Card, LargeTitle, ListCaption, ListRow, Screen, StatusDot, ToggleRow } from "../components";
import type { SettingsProps } from "./types";
import "./screens.css";

// settings: Mac emparejada, notificaciones, seguridad y (opcional) reglas de Claude.
export function Settings(props: SettingsProps) {
  const { mac, notifications, requireFaceId, claude, version } = props;
  return (
    <Screen label="Settings">
      <LargeTitle>Settings</LargeTitle>
      <Card class="settings-mac">
        <div class="settings-mac__head">
          <AppTile size={40} icon="laptopcomputer" />
          <span class="settings-mac__text">
            <strong>{mac.name}</strong>
            <span>
              <StatusDot online={mac.online} />
              {mac.secure}
            </span>
          </span>
        </div>
        <ListRow label="Unpair This Mac" destructive onClick={props.onUnpair} />
      </Card>
      <ListCaption>Notifications</ListCaption>
      <Card>
        {notifications.map((n) => (
          <ToggleRow key={n.id} label={n.label} on={n.on} disabled={n.disabled} onChange={(on) => props.onToggleNotification(n.id, on)} />
        ))}
      </Card>
      <ListCaption>Security</ListCaption>
      <Card>
        <ToggleRow label={requireFaceId.label} on={requireFaceId.on} disabled={requireFaceId.disabled} onChange={props.onToggleFaceId} />
      </Card>
      {claude && claude.length > 0 && (
        <>
          <ListCaption>Claude</ListCaption>
          <Card>
            {claude.map((c) => (
              <ListRow key={c.id} label={c.label} value={c.value} chevron onClick={() => props.onOpenClaude?.(c.id)} />
            ))}
          </Card>
        </>
      )}
      <p class="settings-version">{version}</p>
    </Screen>
  );
}

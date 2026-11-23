import { computed, signal, type ReadonlySignal } from "@preact/signals";
import type { NotificationSettingName, NotificationsInfo } from "../../protocol/commands";
import type { SettingsProps } from "../../ui/screens/types";
import type { AppContext } from "../context";
import { macInfo } from "./home";
import { perform } from "./common";

// settings (SettingsModel.swift, spec R.6): los interruptores de notificaciones de la Mac (comandos permitidos), el
// requisito de Face ID (apagarlo pide Face ID) y lo que es del teléfono (Mac emparejada, desemparejar, versión).

/** Las filas de NOTIFICATIONS del diseño y el interruptor de la Mac que maneja cada una. */
export const NOTIFICATION_ROWS: [string, NotificationSettingName][] = [
  ["Review ready", "review-finished"],
  ["New PR to review", "new-to-review"],
  ["Changes requested on my PRs", "my-feedback"],
  ["Ready to merge", "ready-to-merge"],
  ["CI failed on my PRs", "approved-or-ci"],
];

export const REQUIRE_FACE_ID_LABEL = "Require Face ID for posting to GitHub, merge, push and tests";

export interface SettingsModel {
  props: ReadonlySignal<SettingsProps>;
  load(): Promise<void>;
  setNotification(kind: NotificationSettingName, enabled: boolean): Promise<void>;
  setRequireFaceId(enabled: boolean): Promise<void>;
  unpair(): Promise<void>;
}

export function createSettingsModel(ctx: AppContext, options: { version: string; unpair: () => Promise<void> }): SettingsModel {
  const { store } = ctx;
  const notifications = signal<NotificationsInfo | null>(null);
  const saving = signal(false);

  const model: SettingsModel = {
    props: computed((): SettingsProps => {
      const stale = store.isStale.value;
      const mac = macInfo(store, ctx);
      return {
        mac: { ...mac, secure: mac.online ? "Connected · end-to-end encrypted" : "Offline · end-to-end encrypted" },
        notifications: NOTIFICATION_ROWS.map(([label, kind]) => ({
          id: kind, label, on: notifications.value?.kinds[kind] ?? false, disabled: stale || !notifications.value,
        })),
        requireFaceId: { id: "faceid", label: REQUIRE_FACE_ID_LABEL, on: store.requirePresence.value,
                         disabled: stale || saving.value },
        version: options.version,
        onUnpair: () => void model.unpair(),
        onToggleNotification: (id, on) => void model.setNotification(id as NotificationSettingName, on),
        onToggleFaceId: (on) => void model.setRequireFaceId(on),
      };
    }),
    async load() {
      const info = await perform(ctx, { notifyList: {} });
      if (info) notifications.value = info;
    },
    async setNotification(kind, enabled) {
      const previous = notifications.value;
      if (!previous) return;
      notifications.value = { ...previous, kinds: { ...previous.kinds, [kind]: enabled } };
      const ok = await perform(ctx, { notifySet: { kind, enabled } });
      if (!ok) notifications.value = previous;
    },
    async setRequireFaceId(enabled) {
      if (saving.value) return;
      saving.value = true;
      try {
        // Prenderlo no pide Face ID; apagarlo sí (P.8). La Mac contesta con un `presencePolicy` nuevo.
        const device = await perform(ctx, { remoteSetPresenceRequirement: { device: "", enabled } });
        if (device) store.requirePresence.value = device.requirePresence;
      } finally {
        saving.value = false;
      }
    },
    async unpair() {
      const mac = store.macName.value ?? "your Mac";
      const ok = await ctx.ui.confirm({
        title: `Unpair from ${mac}?`,
        message: "This device forgets its keys and stops getting notifications. Pair it again from PRBar on your Mac.",
        confirmLabel: "Unpair", cancelLabel: "Cancel", destructive: true,
      });
      if (ok) await options.unpair();
    },
  };
  return model;
}

import { signal } from "@preact/signals";
import type { MenuItem } from "../ui/components";
import type { ActionRunner } from "./actions";
import type { Locale } from "./format";
import type { Route } from "./router";
import type { AppStore } from "./store";

// Lo que reciben los modelos de pantalla: el store, el que manda comandos, la navegación y los avisos del shell
// (errores, confirmaciones, menús). Los tests pasan versiones de mentira.

export interface Navigator {
  go(route: Route): void;
  replace(route: Route): void;
  back(): void;
}

export interface ConfirmRequest {
  title: string;
  message?: string | undefined;
  confirmLabel: string;
  cancelLabel: string;
  destructive?: boolean | undefined;
}

export interface UI {
  /** Un error en un banner rojo arriba (se cierra solo o tocándolo). */
  alert(message: string): void;
  confirm(request: ConfirmRequest): Promise<boolean>;
  /** Un menú del sistema ("More"): el id elegido o `null`. */
  menu<T extends string>(label: string, items: MenuItem<T>[]): Promise<T | null>;
  /** Abre GitHub (u otro link https) fuera de la app. */
  openURL(url: string): void;
}

export interface AppContext {
  store: AppStore;
  runner: ActionRunner;
  nav: Navigator;
  ui: UI;
  locale?: Locale | undefined;
}

/** El UI de verdad: signals que dibuja el shell. */
export class ShellUI implements UI {
  readonly alerts = signal<{ id: number; message: string }[]>([]);
  readonly confirmation = signal<(ConfirmRequest & { resolve: (ok: boolean) => void }) | null>(null);
  readonly openMenu = signal<{ label: string; items: MenuItem[]; resolve: (id: string | null) => void } | null>(null);
  #next = 0;

  alert(message: string): void {
    const id = ++this.#next;
    // El mismo aviso dos veces seguidas no se apila.
    if (this.alerts.value.some((a) => a.message === message)) return;
    this.alerts.value = [...this.alerts.value, { id, message }];
    setTimeout(() => this.dismissAlert(id), 6000);
  }

  dismissAlert(id: number): void {
    this.alerts.value = this.alerts.value.filter((a) => a.id !== id);
  }

  confirm(request: ConfirmRequest): Promise<boolean> {
    this.confirmation.value?.resolve(false);
    return new Promise((resolve) => {
      this.confirmation.value = {
        ...request,
        resolve: (ok) => {
          this.confirmation.value = null;
          resolve(ok);
        },
      };
    });
  }

  menu<T extends string>(label: string, items: MenuItem<T>[]): Promise<T | null> {
    this.openMenu.value?.resolve(null);
    return new Promise((resolve) => {
      this.openMenu.value = {
        label, items,
        resolve: (id) => {
          this.openMenu.value = null;
          resolve(id as T | null);
        },
      };
    });
  }

  openURL(url: string): void {
    if (!/^https:\/\//.test(url)) return;
    window.open(url, "_blank", "noopener,noreferrer");
  }
}

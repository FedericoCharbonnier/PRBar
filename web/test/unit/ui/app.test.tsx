// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/preact";
import { afterEach, describe, expect, it } from "vitest";
import { FORGET_FAILED_MESSAGE, Shell } from "../../../src/app/shell";
import type { Storage } from "../../../src/app/session";
import { pairingURL } from "../../../src/protocol/pairingQR";
import { App, InstallGate } from "../../../src/ui/app";
import { flush, makeApp } from "../app/helpers";

afterEach(() => {
  cleanup();
  history.replaceState(null, "", "/");
});

function shellWithFake() {
  const shell = new Shell({ mode: "test", window });
  const app = makeApp();
  shell.use({
    pairing: {
      mac: { accountId: "a", deviceId: "d", relayHost: "relay.example.com", macName: "Studio", macStatic: new Uint8Array(32),
             macSeal: new Uint8Array(32) },
      keys: { relay: new Uint8Array(32), noise: new Uint8Array(32), push: new Uint8Array(32) },
      presence: null, deviceName: "iPhone", pairedAt: 0,
    },
    transport: app.transport, store: app.store, runner: app.runner,
  });
  shell.ready.value = true;
  return { shell, app };
}

describe("App", () => {
  it("fuera de la pantalla de inicio: solo install (y el botón de Android con beforeinstallprompt)", () => {
    render(<InstallGate platform="ios" prompt={() => null} />);
    expect(screen.getByText("Add PRBar to your Home Screen")).toBeTruthy();
    expect(screen.getByText("Tap Share")).toBeTruthy();
    cleanup();
    let prompted = 0;
    const event = Object.assign(new Event("beforeinstallprompt"), { prompt: async () => void prompted++ });
    render(<InstallGate platform="android" prompt={() => event} />);
    fireEvent.click(screen.getByText("Install"));
    expect(prompted).toBe(1);
  });

  it("sin emparejar: welcome → Pair (sin passkey en este navegador) → Paste code → confirmación", async () => {
    const shell = new Shell({ mode: "test", window });
    shell.ready.value = true;
    render(<App shell={shell} />);
    expect(screen.getByText("Welcome to PRBar")).toBeTruthy();
    const name = screen.getByLabelText("Device name") as HTMLInputElement;
    fireEvent.input(name, { target: { value: "Diego's iPhone" } });
    fireEvent.click(screen.getByText("Scan QR on your Mac"));
    await waitFor(() => expect(screen.getByText("Scan the QR code")).toBeTruthy());
    expect(screen.getByRole("alert").textContent).toContain("Face ID couldn't be set up");
    fireEvent.click(screen.getByText("Paste code"));
    const link = pairingURL({ relayHost: "relay.example.com", accountId: "a".repeat(26), pairingId: "b".repeat(16),
                              secret: new Uint8Array(32), macStatic: new Uint8Array(32), macName: "Studio" });
    fireEvent.input(screen.getByLabelText("Pairing code"), { target: { value: link } });
    fireEvent.click(screen.getByText("Pair"));
    await waitFor(() => expect(screen.getByText("Pair with Studio?")).toBeTruthy());
    expect(screen.getByText("relay.example.com")).toBeTruthy();
    fireEvent.click(screen.getByText("Cancel"));
    expect(screen.getByText("Welcome to PRBar")).toBeTruthy();
  });

  it("emparejado: pestañas, insignia, detalle y merge con Face ID", async () => {
    const { shell, app } = shellWithFake();
    render(<App shell={shell} />);
    expect(screen.getAllByText("To Review").length).toBeGreaterThan(0);
    expect(screen.getByText("Refresh expired sessions without logging users out")).toBeTruthy();
    fireEvent.click(screen.getByRole("tab", { name: /My PRs/ }));
    expect(location.hash).toBe("#/mine");
    expect(screen.getByText("Make payment retries idempotent")).toBeTruthy();
    fireEvent.click(screen.getByText("Merge…"));
    expect(location.hash).toBe("#/pr/acme/api/322/merge");
    await waitFor(() => expect(screen.getByText("3 commits become one commit on main.")).toBeTruthy());
    fireEvent.click(screen.getByLabelText("Merge, requires Face ID"));
    await waitFor(() => expect(screen.getByText("Merged")).toBeTruthy());
    expect(app.transport.sent.at(-1)).toMatchObject({ command: { merge: { pr: "acme/api#322" } }, presence: true });
    fireEvent.click(screen.getByText("Done"));
    await flush();
  });

  it("errores en un banner; Settings con la versión", async () => {
    const { shell, app } = shellWithFake();
    shell.router.tab("settings");
    render(<App shell={shell} />);
    await waitFor(() => expect(screen.getByText("Review ready")).toBeTruthy());
    expect(screen.getByText("PRBar 0.1.0 (web)")).toBeTruthy();
    app.transport.setState({ kind: "macOffline", since: null });
    shell.ui.alert("Your Mac is offline.");
    await waitFor(() => expect(screen.getByText("Your Mac is offline.")).toBeTruthy());
  });

  it("punto seguro para recargar con una versión nueva: pestaña raíz, sin hojas ni comandos en curso", async () => {
    const { shell } = shellWithFake();
    render(<App shell={shell} />);
    expect(shell.isSafeToReload()).toBe(true);
    void shell.ui.confirm({ title: "Sure?", confirmLabel: "OK", cancelLabel: "Cancel" });
    expect(shell.isSafeToReload()).toBe(false);
    shell.ui.confirmation.value!.resolve(false);
    expect(shell.isSafeToReload()).toBe(true);
    shell.router.go({ kind: "pr", pr: "acme/api#322", screen: "merge" });
    expect(shell.isSafeToReload()).toBe(false);
  });

  it("un emparejamiento que falla sobre una sesión se puede cancelar desde welcome", async () => {
    const { shell } = shellWithFake();
    shell.pairingOpen.value = true;
    shell.pairing.openLink("not a pairing link");
    render(<App shell={shell} />);
    expect(screen.getByText("Welcome to PRBar")).toBeTruthy();
    fireEvent.click(screen.getByText("Cancel"));
    expect(shell.pairingOpen.value).toBe(false);
    await waitFor(() => expect(screen.getAllByText("To Review").length).toBeGreaterThan(0));
  });

  it("sin sesión, welcome no tiene Cancel", () => {
    const shell = new Shell({ mode: "test", window });
    shell.ready.value = true;
    render(<App shell={shell} />);
    expect(screen.queryByText("Cancel")).toBeNull();
  });

  it("si el arranque tira, muestra el error con Try Again (no una pantalla en blanco)", async () => {
    const stored = { mac: { macName: "Studio" } };
    const storage = {
      keys: { loadPairing: async () => stored, hasPairing: async () => true },
    } as unknown as Storage;
    const shell = new Shell({
      mode: "test", window, openStorage: async () => storage,
      openSession: async () => { throw new Error("corrupt pairing"); },
    });
    const errors = console.error;
    console.error = () => {};
    try {
      await shell.boot();
    } finally {
      console.error = errors;
    }
    expect(shell.ready.value).toBe(true);
    expect(shell.bootFailed.value).toBe(true);
    render(<App shell={shell} />);
    expect(screen.getByText("PRBar couldn’t start")).toBeTruthy();
    expect(screen.getByText("Try Again")).toBeTruthy();
  });

  it("desemparejar: si las claves no se pueden borrar, lo dice en welcome", async () => {
    const fail = async () => { throw new DOMException("lost", "UnknownError"); };
    const storage = {
      keys: { clear: fail, close: () => {} },
      cache: { clear: async () => {}, close: () => {} },
      seen: { clear: async () => {}, close: () => {} },
    } as unknown as Storage;
    const shell = new Shell({ mode: "test", window, openStorage: async () => storage });
    const app = makeApp();
    shell.use({ pairing: { mac: { macName: "Studio" } } as never, transport: app.transport, store: app.store,
                runner: app.runner });
    shell.ready.value = true;
    const errors = console.error;
    console.error = () => {};
    try {
      await shell.unpair();
    } finally {
      console.error = errors;
    }
    expect(shell.active.value).toBeNull();
    expect(shell.pairing.notice.value).toBe(FORGET_FAILED_MESSAGE);
  });
});

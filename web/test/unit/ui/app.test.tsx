// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/preact";
import { afterEach, describe, expect, it } from "vitest";
import { Shell } from "../../../src/app/shell";
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
});

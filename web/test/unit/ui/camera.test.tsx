// @vitest-environment happy-dom
import { cleanup, render, waitFor } from "@testing-library/preact";
import { afterEach, describe, expect, it } from "vitest";
import { Camera, cameraNeedsRestart } from "../../../src/ui/Camera";

afterEach(cleanup);

class FakeTrack extends EventTarget {
  readyState = "live";
  stop() {
    this.readyState = "ended";
  }
  /** iOS la corta sola (la app pasó a segundo plano). */
  end() {
    this.readyState = "ended";
    this.dispatchEvent(new Event("ended"));
  }
}

function fakeCamera() {
  const tracks: FakeTrack[] = [];
  Object.defineProperty(navigator, "mediaDevices", {
    configurable: true,
    value: {
      getUserMedia: async () => {
        const track = new FakeTrack();
        tracks.push(track);
        return { getTracks: () => [track], getVideoTracks: () => [track] };
      },
    },
  });
  HTMLMediaElement.prototype.play = async () => {};
  // happy-dom solo acepta un MediaStream de verdad.
  Object.defineProperty(HTMLMediaElement.prototype, "srcObject", { configurable: true, writable: true, value: null });
  return tracks;
}

let visibility: DocumentVisibilityState = "visible";
Object.defineProperty(document, "visibilityState", { configurable: true, get: () => visibility });

describe("Camera", () => {
  it("cameraNeedsRestart: sin pistas o sin ninguna viva", () => {
    expect(cameraNeedsRestart(null)).toBe(true);
    expect(cameraNeedsRestart([{ readyState: "ended" }])).toBe(true);
    expect(cameraNeedsRestart([{ readyState: "live" }])).toBe(false);
  });

  it("si iOS corta la cámara en segundo plano, la vuelve a pedir al volver", async () => {
    const tracks = fakeCamera();
    const { unmount } = render(<Camera onScan={() => {}} onError={() => {}} />);
    await waitFor(() => expect(tracks).toHaveLength(1));
    visibility = "hidden";
    document.dispatchEvent(new Event("visibilitychange"));
    tracks[0]!.end();
    // En segundo plano no se pide.
    await new Promise((r) => setTimeout(r, 10));
    expect(tracks).toHaveLength(1);
    visibility = "visible";
    document.dispatchEvent(new Event("visibilitychange"));
    await waitFor(() => expect(tracks).toHaveLength(2));
    // Volver con la cámara andando no la pide otra vez.
    document.dispatchEvent(new Event("visibilitychange"));
    await new Promise((r) => setTimeout(r, 10));
    expect(tracks).toHaveLength(2);
    unmount();
    expect(tracks[1]!.readyState).toBe("ended");
  });

  it("una pista que termina con la pantalla a la vista se reemplaza enseguida", async () => {
    const tracks = fakeCamera();
    render(<Camera onScan={() => {}} onError={() => {}} />);
    await waitFor(() => expect(tracks).toHaveLength(1));
    tracks[0]!.end();
    await waitFor(() => expect(tracks).toHaveLength(2));
  });
});

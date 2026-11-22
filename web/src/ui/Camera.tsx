import { useEffect, useRef } from "preact/hooks";

// La cámara de pair:scan: `getUserMedia` con la cámara trasera y `jsqr` sobre un canvas ~8 veces por segundo (Safari
// no tiene `BarcodeDetector`). `jsqr` se carga recién acá (es grande y solo hace falta para escanear; el service worker
// igual lo precarga). Al salir de la pantalla se apagan las pistas (se va la luz verde). iOS corta la cámara cuando la
// app pasa a segundo plano: al volver (o si la pista termina) se pide de nuevo, en vez de quedar el video en negro.

const INTERVAL_MS = 125;
/** Se escala el cuadro para que jsqr no trabaje con imágenes enormes. */
const MAX_SIDE = 640;

type Decode = typeof import("jsqr").default;

/** Si la cámara hay que pedirla de nuevo: no hay pista de video viva (terminó, o nunca arrancó). */
export function cameraNeedsRestart(tracks: readonly { readyState: string }[] | null): boolean {
  return !tracks || !tracks.some((track) => track.readyState === "live");
}

export function Camera({ onScan, onError }: { onScan: (text: string) => void; onError: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const scan = useRef(onScan);
  const fail = useRef(onError);
  scan.current = onScan;
  fail.current = onError;

  useEffect(() => {
    let stream: MediaStream | null = null;
    let timer: ReturnType<typeof setInterval> | null = null;
    let stopped = false;
    let starting = false;
    let decode: Decode | null = null;
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d", { willReadFrequently: true });
    let last = "";

    import("jsqr").then((module) => (decode = module.default), () => {
      if (!stopped) fail.current();
    });

    const tick = () => {
      const v = video.current;
      if (!decode || !v || !context || v.readyState < 2 || v.videoWidth === 0) return;
      const scale = Math.min(1, MAX_SIDE / Math.max(v.videoWidth, v.videoHeight));
      const w = Math.round(v.videoWidth * scale);
      const h = Math.round(v.videoHeight * scale);
      canvas.width = w;
      canvas.height = h;
      context.drawImage(v, 0, 0, w, h);
      const code = decode(context.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: "dontInvert" });
      // El mismo texto inválido una y otra vez no se vuelve a reportar.
      if (code?.data && code.data !== last) {
        last = code.data;
        scan.current(code.data);
      }
    };

    const release = () => {
      for (const track of stream?.getTracks() ?? []) {
        track.removeEventListener("ended", ended);
        track.stop();
      }
      stream = null;
      if (video.current) video.current.srcObject = null;
    };

    const start = async () => {
      if (stopped || starting) return;
      if (!navigator.mediaDevices?.getUserMedia) {
        fail.current();
        return;
      }
      starting = true;
      let next: MediaStream;
      try {
        next = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
      } catch {
        if (!stopped) fail.current();
        return;
      } finally {
        starting = false;
      }
      if (stopped) {
        for (const track of next.getTracks()) track.stop();
        return;
      }
      release();
      stream = next;
      for (const track of next.getVideoTracks()) track.addEventListener("ended", ended);
      const v = video.current;
      if (!v) return;
      v.srcObject = next;
      await v.play().catch(() => {});
      timer ??= setInterval(tick, INTERVAL_MS);
    };

    const restartIfNeeded = () => {
      if (stopped || document.visibilityState !== "visible") return;
      if (cameraNeedsRestart(stream?.getVideoTracks() ?? null)) void start();
    };
    // La pista terminó (iOS la corta en segundo plano): si se ve la pantalla, otra ya; si no, al volver.
    function ended() {
      restartIfNeeded();
    }

    document.addEventListener("visibilitychange", restartIfNeeded);
    addEventListener("pageshow", restartIfNeeded);
    void start();

    return () => {
      stopped = true;
      document.removeEventListener("visibilitychange", restartIfNeeded);
      removeEventListener("pageshow", restartIfNeeded);
      if (timer !== null) clearInterval(timer);
      release();
    };
  }, []);

  return <video ref={video} muted playsInline autoPlay aria-label="Camera" />;
}

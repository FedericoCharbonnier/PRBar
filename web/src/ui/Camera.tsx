import jsQR from "jsqr";
import { useEffect, useRef } from "preact/hooks";

// La cámara de pair:scan: `getUserMedia` con la cámara trasera y `jsqr` sobre un canvas ~8 veces por segundo (Safari
// no tiene `BarcodeDetector`). Al salir de la pantalla se apagan las pistas (se va la luz verde).

const INTERVAL_MS = 125;
/** Se escala el cuadro para que jsqr no trabaje con imágenes enormes. */
const MAX_SIDE = 640;

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
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d", { willReadFrequently: true });
    let last = "";

    const tick = () => {
      const v = video.current;
      if (!v || !context || v.readyState < 2 || v.videoWidth === 0) return;
      const scale = Math.min(1, MAX_SIDE / Math.max(v.videoWidth, v.videoHeight));
      const w = Math.round(v.videoWidth * scale);
      const h = Math.round(v.videoHeight * scale);
      canvas.width = w;
      canvas.height = h;
      context.drawImage(v, 0, 0, w, h);
      const code = jsQR(context.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: "dontInvert" });
      // El mismo texto inválido una y otra vez no se vuelve a reportar.
      if (code?.data && code.data !== last) {
        last = code.data;
        scan.current(code.data);
      }
    };

    (async () => {
      if (!navigator.mediaDevices?.getUserMedia) {
        fail.current();
        return;
      }
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
      } catch {
        if (!stopped) fail.current();
        return;
      }
      if (stopped) {
        for (const track of stream.getTracks()) track.stop();
        return;
      }
      const v = video.current;
      if (!v) return;
      v.srcObject = stream;
      await v.play().catch(() => {});
      timer = setInterval(tick, INTERVAL_MS);
    })();

    return () => {
      stopped = true;
      if (timer !== null) clearInterval(timer);
      for (const track of stream?.getTracks() ?? []) track.stop();
      if (video.current) video.current.srcObject = null;
    };
  }, []);

  return <video ref={video} muted playsInline autoPlay aria-label="Camera" />;
}

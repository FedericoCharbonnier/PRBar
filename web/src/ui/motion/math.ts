// Cuentas de los gestos y las animaciones (funciones puras, con pruebas en test/unit/ui/motion.test.ts). Los valores
// imitan a UIKit: el pop interactivo de UINavigationController, el arrastre de una hoja y el rebote de UIScrollView.

/** La curva de las transiciones del sistema (push, hojas): parecida a un resorte críticamente amortiguado. */
export const EASE_SPRING = "cubic-bezier(0.32, 0.72, 0, 1)";
export const PUSH_MS = 420;
export const SHEET_MS = 460;

/** Ancho de la zona del borde izquierdo donde empieza el gesto de volver. */
export const EDGE_WIDTH = 20;
/** Cuánto se corre la pantalla de abajo (fracción del ancho) cuando la de arriba entra por completo. */
export const PARALLAX = 0.3;
/** Oscurecimiento máximo de la pantalla de abajo. */
export const DIM = 0.12;

export const clamp = (value: number, min: number, max: number): number => Math.min(max, Math.max(min, value));

/** El rebote de UIScrollView: pasado el límite, cada pixel de dedo mueve menos (`c` = 0.55 como iOS). */
export function rubberBand(offset: number, dimension: number, c = 0.55): number {
  if (dimension <= 0) return 0;
  const sign = Math.sign(offset);
  const x = Math.abs(offset);
  return sign * (1 - 1 / ((x * c) / dimension + 1)) * dimension;
}

/** Progreso del gesto de volver (0 = sin mover, 1 = la pantalla salió entera). */
export function swipeProgress(dx: number, width: number): number {
  return width > 0 ? clamp(dx / width, 0, 1) : 0;
}

/** Al soltar: ¿vuelve (pop) o se queda? Pasado un tercio del ancho, o con un tirón hacia la derecha. Un tirón hacia la
 *  izquierda cancela aunque haya pasado el tercio. Velocidad en px/ms. */
export function shouldCompletePop(dx: number, velocity: number, width: number): boolean {
  if (velocity < -0.3) return false;
  if (velocity > 0.5) return true;
  return dx > width / 3;
}

/** Posiciones de las dos pantallas para un progreso dado: la de arriba (x en px) y la de abajo (paralaje y sombra). */
export function popFrame(progress: number, width: number): { topX: number; underX: number; dim: number } {
  const p = clamp(progress, 0, 1);
  return { topX: p * width, underX: -(1 - p) * PARALLAX * width, dim: (1 - p) * DIM };
}

/** Duración del resto de una animación después de soltar: lo que falta a la velocidad del dedo, entre `min` y `max`. */
export function settleDuration(remaining: number, velocity: number, min = 180, max = PUSH_MS): number {
  const speed = Math.abs(velocity);
  if (speed < 0.05) return max;
  return clamp(Math.abs(remaining) / speed, min, max);
}

/** ¿Se cierra la hoja al soltarla? Bajada más allá del 35 % de su alto, o un tirón hacia abajo. */
export function shouldDismissSheet(dy: number, velocity: number, height: number): boolean {
  if (velocity < -0.2) return false;
  if (velocity > 0.6 && dy > 8) return true;
  return dy > height * 0.35;
}

/** Desplazamiento visible de la hoja para un arrastre `dy`: hacia abajo sigue al dedo, hacia arriba rebota. */
export function sheetOffset(dy: number, height: number): number {
  return dy >= 0 ? dy : rubberBand(dy, height);
}

/** Lo que se ve del "tirar para actualizar": el contenido baja con resistencia y el indicador se va completando. */
export const REFRESH_THRESHOLD = 72;
export const REFRESH_HOLD = 56;

export function pullOffset(dy: number, height: number): number {
  return dy <= 0 ? 0 : rubberBand(dy, height, 0.55);
}

export function pullProgress(offset: number): number {
  return clamp(offset / REFRESH_THRESHOLD, 0, 1);
}

/** Cuántos rayos del indicador de actividad (de 8) se ven para un progreso. */
export function spokesFor(progress: number, total = 8): number {
  return Math.round(clamp(progress, 0, 1) * total);
}

/** ¿Es un gesto horizontal? Se decide después de moverse `slop` px; vertical gana en el empate. */
export function gestureAxis(dx: number, dy: number, slop = 8): "x" | "y" | null {
  if (Math.hypot(dx, dy) < slop) return null;
  return Math.abs(dx) > Math.abs(dy) * 1.2 ? "x" : "y";
}

export interface Sample {
  t: number;
  v: number;
}

/** Velocidad (unidades/ms) con las muestras de los últimos `window` ms, como UIPanGestureRecognizer. */
export function velocityOf(samples: readonly Sample[], window = 100): number {
  if (samples.length < 2) return 0;
  const last = samples[samples.length - 1]!;
  let first = last;
  for (let i = samples.length - 2; i >= 0; i--) {
    const s = samples[i]!;
    if (last.t - s.t > window) break;
    first = s;
  }
  const dt = last.t - first.t;
  return dt > 0 ? (last.v - first.v) / dt : 0;
}

/** Agrega una muestra y deja solo las recientes. */
export function addSample(samples: Sample[], t: number, v: number, keep = 200): Sample[] {
  const next = samples.filter((s) => t - s.t <= keep);
  next.push({ t, v });
  return next;
}

/** La escala y el corrimiento de la pantalla de atrás cuando se presenta una hoja grande (estilo tarjeta). */
export function cardScale(width: number, inset = 16): number {
  return width > 0 ? (width - inset * 2) / width : 1;
}

// Animaciones con la Web Animations API (sin estilos en línea en el HTML: todo pasa por CSSOM, que la CSP permite).
// Solo `transform` y `opacity`; `will-change` mientras dura la animación.

export function reducedMotion(): boolean {
  try {
    return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return false;
  }
}

export interface MotionOptions {
  duration: number;
  easing?: string;
  delay?: number;
  /** Deja el último cuadro aplicado al terminar (por defecto se suelta y manda el CSS). */
  hold?: boolean;
}

/** Anima `el` y devuelve una promesa que se cumple al terminar o al cancelarse. Sin WAAPI (happy-dom) no hace nada. */
export function animate(el: Element | null | undefined, keyframes: Keyframe[], options: MotionOptions): Promise<void> {
  const target = el as HTMLElement | null | undefined;
  if (!target || typeof target.animate !== "function") return Promise.resolve();
  const props = new Set<string>();
  for (const k of keyframes) for (const key of Object.keys(k)) if (key === "transform" || key === "opacity") props.add(key);
  if (props.size > 0) target.style.willChange = [...props].join(", ");
  const animation = target.animate(keyframes, {
    duration: options.duration,
    easing: options.easing ?? "ease",
    delay: options.delay ?? 0,
    fill: options.hold ? "forwards" : "backwards",
  });
  return animation.finished.then(
    () => undefined,
    () => undefined,
  ).finally(() => {
    target.style.willChange = "";
  });
}

/** Cancela las animaciones de WAAPI de `el` (antes de un gesto interactivo o de otra animación). */
export function cancelAnimations(el: Element | null | undefined): void {
  const target = el as HTMLElement | null | undefined;
  if (!target || typeof target.getAnimations !== "function") return;
  for (const a of target.getAnimations()) a.cancel();
}

/** Copia visual de un elemento que se va (la hoja que se cierra, el menú, el aviso): el original ya se desmonta, la
 *  copia queda fija en el mismo lugar, sin eventos ni accesibilidad, y se anima con `keyframes` antes de borrarse. */
export function ghost(el: Element | null | undefined, keyframes: (node: HTMLElement) => Keyframe[], options: MotionOptions): void {
  const source = el as HTMLElement | null | undefined;
  if (!source || !source.isConnected || typeof source.animate !== "function" || typeof document === "undefined") return;
  const rect = source.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return;
  const copy = source.cloneNode(true) as HTMLElement;
  // Los textos escritos no viajan con cloneNode.
  const fields = source.querySelectorAll("textarea, input");
  copy.querySelectorAll("textarea, input").forEach((f, i) => {
    const original = fields[i] as HTMLInputElement | undefined;
    if (original && "value" in f) (f as HTMLInputElement).value = original.value;
  });
  copy.setAttribute("aria-hidden", "true");
  copy.setAttribute("inert", "");
  copy.classList.add("ghost");
  const s = copy.style;
  s.position = "fixed";
  s.left = `${rect.left}px`;
  s.top = `${rect.top}px`;
  s.width = `${rect.width}px`;
  s.height = `${rect.height}px`;
  s.margin = "0";
  s.right = "auto";
  s.bottom = "auto";
  s.pointerEvents = "none";
  const host = document.getElementById("app") ?? document.body;
  host.appendChild(copy);
  void animate(copy, keyframes(copy), { ...options, hold: true }).then(() => copy.remove());
}

/** Rebote corto (íconos de la barra de pestañas, insignias). */
export function bounce(el: Element | null | undefined, scale = 0.84): Promise<void> {
  if (reducedMotion()) return Promise.resolve();
  return animate(el, [
    { transform: "scale(1)" },
    { transform: `scale(${scale})`, offset: 0.3 },
    { transform: "scale(1.06)", offset: 0.7 },
    { transform: "scale(1)" },
  ], { duration: 380, easing: "ease-out" });
}

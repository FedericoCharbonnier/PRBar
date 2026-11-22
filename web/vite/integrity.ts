// Subresource Integrity para el `index.html` construido (spec W.7): cada `<script src>` y `<link rel=stylesheet>` (y
// `modulepreload`) a un archivo del mismo origen lleva `integrity="sha256-…"` y `crossorigin`. Así un asset envenenado
// en la caché HTTP no corre aunque el `index.html` sea el bueno. Sin dependencias de node: el hash lo pasa quien llama.

const TAG = /<(script|link)\b[^>]*>/gi;

function attribute(tag: string, name: string): string | null {
  const match = new RegExp(`\\s${name}(?:\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+)))?`, "i").exec(tag);
  if (!match) return null;
  return match[1] ?? match[2] ?? match[3] ?? "";
}

/** Agrega `integrity` y `crossorigin` a los scripts y hojas de estilo locales (rutas absolutas `/…`). `hash` devuelve el
 *  SHA-256 en base64 del archivo en esa ruta y lanza si no existe. Los que ya tienen `integrity` quedan como están. */
export function addIntegrity(html: string, hash: (path: string) => string): string {
  return html.replace(TAG, (tag, name: string) => {
    let url: string | null;
    if (name.toLowerCase() === "script") {
      url = attribute(tag, "src");
    } else {
      const rel = (attribute(tag, "rel") ?? "").toLowerCase().split(/\s+/);
      url = rel.includes("stylesheet") || rel.includes("modulepreload") ? attribute(tag, "href") : null;
    }
    if (!url || !url.startsWith("/") || url.startsWith("//") || attribute(tag, "integrity") !== null) return tag;
    const extra = ` integrity="sha256-${hash(url)}"` + (attribute(tag, "crossorigin") === null ? " crossorigin" : "");
    const selfClosing = tag.endsWith("/>");
    const head = tag.slice(0, selfClosing ? -2 : -1).trimEnd();
    return `${head}${extra}${selfClosing ? " />" : ">"}`;
  });
}

// Precarga verificada del service worker (spec W.1). `sw.js` siempre se baja fresco del relay, así que es el ancla de
// confianza: trae el SHA-256 de cada archivo que precarga. Al instalar, cada archivo se pide saltando la caché HTTP
// (`cache: "reload"`) y se compara con su hash; si uno no coincide, la instalación falla y no se guarda nada. Así una
// copia envenenada que haya quedado en la caché HTTP (por ejemplo, de un relay comprometido, con `immutable` por un
// año) no vuelve a entrar en la caché del service worker.

/** Ruta → SHA-256 del contenido en base64 (estándar, con relleno). */
export type PrecacheManifest = Readonly<Record<string, string>>;

export async function sha256Base64(data: ArrayBuffer | Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Verifica un cuerpo contra el hash esperado. Lanza si no coincide (o si no hay hash para esa ruta). */
export async function verifyBody(path: string, body: ArrayBuffer | Uint8Array, expected: string | undefined): Promise<void> {
  if (!expected) throw new Error(`precache: no hash for ${path}`);
  const actual = await sha256Base64(body);
  if (actual !== expected) throw new Error(`precache: ${path} does not match its hash`);
}

/** Baja todos los archivos del manifiesto saltando la caché HTTP y los verifica. Devuelve las respuestas solo si todas
 *  pasan; con una sola que falle (red, status o hash) lanza y no devuelve ninguna. */
export async function fetchVerified(
  manifest: PrecacheManifest,
  fetchFn: (path: string, init: RequestInit) => Promise<Response>,
): Promise<Array<[string, Response]>> {
  return Promise.all(Object.entries(manifest).map(async ([path, expected]): Promise<[string, Response]> => {
    const response = await fetchFn(path, { cache: "reload" });
    if (!response.ok) throw new Error(`precache: ${path} answered ${response.status}`);
    await verifyBody(path, await response.clone().arrayBuffer(), expected);
    return [path, response];
  }));
}

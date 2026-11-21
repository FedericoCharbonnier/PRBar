// La base IndexedDB `prbar` (spec W.3): claves envueltas, caché de pantallas e ids de pushes vistos. La usan la app y
// el service worker (que lee la clave de push y los ids vistos).

export const DB_NAME = "prbar";
const DB_VERSION = 1;

export type StoreName = "keys" | "cache" | "prs" | "seen";

export interface DatabaseOptions {
  /** Por defecto el `indexedDB` global (los tests pasan `fake-indexeddb`). */
  indexedDB?: IDBFactory;
  name?: string;
}

export function openDatabase(options: DatabaseOptions = {}): Promise<IDBDatabase> {
  const factory = options.indexedDB ?? globalThis.indexedDB;
  return new Promise((resolve, reject) => {
    const request = factory.open(options.name ?? DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      for (const name of ["keys", "cache", "seen"]) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name);
      }
      if (!db.objectStoreNames.contains("prs")) db.createObjectStore("prs", { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("IndexedDB is blocked by another tab"));
  });
}

function done(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error ?? new Error("transaction aborted"));
  });
}

function result<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function getValue<T>(db: IDBDatabase, store: StoreName, key: IDBValidKey): Promise<T | undefined> {
  return (await result(db.transaction(store, "readonly").objectStore(store).get(key))) as T | undefined;
}

export async function getAllValues<T>(db: IDBDatabase, store: StoreName): Promise<T[]> {
  return (await result(db.transaction(store, "readonly").objectStore(store).getAll())) as T[];
}

/** Escribe varias cosas en una transacción (todo o nada). */
export async function write(db: IDBDatabase, stores: StoreName[],
                            fn: (get: (store: StoreName) => IDBObjectStore) => void): Promise<void> {
  const transaction = db.transaction(stores, "readwrite");
  fn((store) => transaction.objectStore(store));
  await done(transaction);
}

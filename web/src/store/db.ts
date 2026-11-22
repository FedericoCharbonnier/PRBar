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

/** La conexión se perdió (WebKit suelta la de una página en segundo plano: "Connection to Indexed Database server
 *  lost") o se cerró: abrir otra puede andar. */
function connectionLost(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name;
  return name === "InvalidStateError" || name === "UnknownError";
}

/** La base `prbar` con una conexión que se rehace: si el navegador la cierra (`close`, `versionchange`) o una
 *  operación falla porque se perdió, se abre otra y se reintenta una vez. */
export class Database {
  readonly #options: DatabaseOptions;
  #db: IDBDatabase | null = null;
  #opening: Promise<IDBDatabase> | null = null;

  private constructor(options: DatabaseOptions) {
    this.#options = options;
  }

  static async open(options: DatabaseOptions = {}): Promise<Database> {
    const database = new Database(options);
    await database.connection();
    return database;
  }

  /** La conexión actual (abre una si hace falta). */
  connection(): Promise<IDBDatabase> {
    if (this.#db) return Promise.resolve(this.#db);
    this.#opening ??= openDatabase(this.#options).then(
      (db) => {
        this.#opening = null;
        this.#db = db;
        const lost = () => {
          if (this.#db === db) this.#db = null;
        };
        db.onclose = lost;
        // Otra conexión quiere borrar o actualizar la base: se suelta esta (la próxima operación abre otra).
        db.onversionchange = () => {
          lost();
          db.close();
        };
        return db;
      },
      (error: unknown) => {
        this.#opening = null;
        throw error;
      },
    );
    return this.#opening;
  }

  /** Corre `fn` con la conexión; si falla porque la conexión se perdió, abre otra y reintenta una vez. */
  async run<T>(fn: (db: IDBDatabase) => Promise<T>): Promise<T> {
    const db = await this.connection();
    try {
      return await fn(db);
    } catch (error) {
      if (!connectionLost(error)) throw error;
      if (this.#db === db) this.#db = null;
      try {
        db.close();
      } catch {
        // Ya estaba cerrada.
      }
      return fn(await this.connection());
    }
  }

  /** Suelta la conexión (la próxima operación abre otra). */
  close(): void {
    const db = this.#db;
    this.#db = null;
    db?.close();
  }
}

/** Borra la base entera (último recurso al desemparejar si no se pudo vaciar). Falla si queda bloqueada. */
export function deleteDatabase(options: DatabaseOptions = {}): Promise<void> {
  const factory = options.indexedDB ?? globalThis.indexedDB;
  return new Promise((resolve, reject) => {
    const request = factory.deleteDatabase(options.name ?? DB_NAME);
    // Con `blocked` sigue esperando a que las otras conexiones se suelten (lo hacen con `versionchange`); si no, falla.
    const timer = setTimeout(() => reject(new Error("IndexedDB is blocked by another tab")), 5000);
    request.onsuccess = () => {
      clearTimeout(timer);
      resolve();
    };
    request.onerror = () => {
      clearTimeout(timer);
      reject(request.error);
    };
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

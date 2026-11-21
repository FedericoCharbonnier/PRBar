import type { RemoteHome, RemotePRDetail } from "../protocol/commands";
import { getAllValues, getValue, openDatabase, write, type DatabaseOptions } from "./db";

// Caché de lo que muestran las pantallas sin conexión (R.3, `home:offline`): el último `home` y hasta 50 detalles de
// PR (LRU), más el último `rev` visto del buzón (P.16 M2). Solo datos de PRs; se borra al desemparejar.

export const MAX_CACHED_PRS = 50;

export interface CachedHome {
  home: RemoteHome;
  /** Cuándo lo escribió la Mac (o cuándo llegó en vivo), en ms: el "Last updated". */
  updatedAt: number;
}

export interface CachedPR {
  detail: RemotePRDetail;
  updatedAt: number;
}

interface PRRecord extends CachedPR {
  id: string;
  /** Orden de uso para el LRU. */
  usedAt: number;
}

const HOME = "home";
const MAILBOX_REVS = "mailboxRevisions";

export class Cache {
  readonly #db: IDBDatabase;
  readonly #max: number;
  #tick = 0;

  private constructor(db: IDBDatabase, max: number) {
    this.#db = db;
    this.#max = max;
  }

  static async open(options: DatabaseOptions & { maxPRs?: number } = {}): Promise<Cache> {
    const cache = new Cache(await openDatabase(options), options.maxPRs ?? MAX_CACHED_PRS);
    for (const record of await getAllValues<PRRecord>(cache.#db, "prs")) cache.#tick = Math.max(cache.#tick, record.usedAt);
    return cache;
  }

  async saveHome(home: RemoteHome, updatedAt: number): Promise<void> {
    const value: CachedHome = { home, updatedAt };
    await write(this.#db, ["cache"], (store) => store("cache").put(value, HOME));
  }

  async loadHome(): Promise<CachedHome | null> {
    return (await getValue<CachedHome>(this.#db, "cache", HOME)) ?? null;
  }

  async savePR(id: string, detail: RemotePRDetail, updatedAt: number): Promise<void> {
    const record: PRRecord = { id, detail, updatedAt, usedAt: ++this.#tick };
    await write(this.#db, ["prs"], (store) => store("prs").put(record));
    const all = await getAllValues<PRRecord>(this.#db, "prs");
    if (all.length <= this.#max) return;
    const evicted = all.sort((a, b) => a.usedAt - b.usedAt).slice(0, all.length - this.#max);
    await write(this.#db, ["prs"], (store) => {
      for (const old of evicted) store("prs").delete(old.id);
    });
  }

  /** El detalle guardado de un PR (cuenta como uso para el LRU). */
  async loadPR(id: string): Promise<CachedPR | null> {
    const record = await getValue<PRRecord>(this.#db, "prs", id);
    if (!record) return null;
    record.usedAt = ++this.#tick;
    await write(this.#db, ["prs"], (store) => store("prs").put(record));
    return { detail: record.detail, updatedAt: record.updatedAt };
  }

  async saveMailboxRevisions(revisions: Record<string, number>): Promise<void> {
    await write(this.#db, ["cache"], (store) => store("cache").put({ ...revisions }, MAILBOX_REVS));
  }

  async loadMailboxRevisions(): Promise<Record<string, number>> {
    return (await getValue<Record<string, number>>(this.#db, "cache", MAILBOX_REVS)) ?? {};
  }

  /** Al desemparejar (o con un `bye(revoked)`). */
  async clear(): Promise<void> {
    await write(this.#db, ["cache", "prs"], (store) => {
      store("cache").clear();
      store("prs").clear();
    });
  }

  close(): void {
    this.#db.close();
  }
}

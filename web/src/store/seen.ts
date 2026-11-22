import { Database, getValue, write, type DatabaseOptions } from "./db";

// Los ids de los últimos 200 pushes mostrados (spec W.6, P.9): un push repetido (el relay o el servicio de push lo
// mandan de nuevo) muestra el genérico en vez del mismo texto otra vez. Lo usa el service worker.

export const MAX_SEEN = 200;
const KEY = "ids";

export class SeenIds {
  readonly #db: Database;

  private constructor(db: Database) {
    this.#db = db;
  }

  static async open(options: DatabaseOptions = {}): Promise<SeenIds> {
    return new SeenIds(await Database.open(options));
  }

  /** Los ids vistos, del más viejo al más nuevo. */
  async list(): Promise<string[]> {
    return (await this.#db.run((db) => getValue<string[]>(db, "seen", KEY))) ?? [];
  }

  async has(id: string): Promise<boolean> {
    return (await this.list()).includes(id);
  }

  /** Anota un id (se llama recién cuando el push pasó todo lo demás: uno rechazado no gasta su id). */
  async add(id: string): Promise<void> {
    const ids = (await this.list()).filter((seen) => seen !== id);
    ids.push(id);
    await this.#db.run((db) => write(db, ["seen"], (store) => store("seen").put(ids.slice(-MAX_SEEN), KEY)));
  }

  async clear(): Promise<void> {
    await this.#db.run((db) => write(db, ["seen"], (store) => store("seen").clear()));
  }

  close(): void {
    this.#db.close();
  }
}

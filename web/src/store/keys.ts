import { utf8, type Bytes } from "../crypto/bytes";
import type { DeviceKeys, PairedMac, PresenceCredential } from "../transport/types";
import { Database, getValue, write, type DatabaseOptions } from "./db";

// Las claves del teléfono (spec W.3): las privadas (`deviceRelayKey`, `deviceStatic`, `devicePushKey`) se guardan
// cifradas con una clave AES-GCM-256 de WebCrypto creada con `extractable: false` y guardada como `CryptoKey` en
// IndexedDB. Protege contra copiar el almacenamiento, no contra código en la página (riesgo aceptado, decisión 2). La
// Mac emparejada y la passkey son públicas y van en claro.

/** Todo lo que el teléfono recuerda de un emparejamiento. */
export interface StoredPairing {
  mac: PairedMac;
  keys: DeviceKeys;
  /** `null`: emparejado sin passkey (los comandos gated quedan bloqueados en la Mac). */
  presence: PresenceCredential | null;
  /** El nombre que eligió el usuario al emparejar. */
  deviceName: string;
  /** Milisegundos. */
  pairedAt: number;
}

/** Lo que necesita el service worker para abrir un push (`push/open.ts`). */
export interface PushKeys {
  devicePush: Bytes;
  macSeal: Bytes;
  account: string;
  device: string;
}

interface WrappedKey {
  iv: Uint8Array;
  ciphertext: ArrayBuffer;
}

interface PairingRecord {
  mac: PairedMac;
  presence: PresenceCredential | null;
  deviceName: string;
  pairedAt: number;
  wrapped: Record<keyof DeviceKeys, WrappedKey>;
}

const WRAP_KEY = "wrapKey";
const PAIRING = "pairing";
const KEY_NAMES = ["relay", "noise", "push"] as const;

/** Datos asociados: una privada envuelta no se puede hacer pasar por otra. */
const aad = (name: string) => utf8(`PRBar key v1|${name}`);

export class KeyStore {
  readonly #db: Database;

  private constructor(db: Database) {
    this.#db = db;
  }

  static async open(options: DatabaseOptions = {}): Promise<KeyStore> {
    return new KeyStore(await Database.open(options));
  }

  /** Guarda un emparejamiento nuevo (reemplaza el anterior). */
  async savePairing(pairing: StoredPairing): Promise<void> {
    const wrapKey = await this.#wrapKey(true);
    const wrapped = {} as Record<keyof DeviceKeys, WrappedKey>;
    for (const name of KEY_NAMES) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad(name) }, wrapKey!,
                                                     pairing.keys[name]);
      wrapped[name] = { iv, ciphertext };
    }
    const record: PairingRecord = { mac: pairing.mac, presence: pairing.presence, deviceName: pairing.deviceName,
                                    pairedAt: pairing.pairedAt, wrapped };
    await this.#db.run((db) => write(db, ["keys"], (store) => store("keys").put(record, PAIRING)));
  }

  /** El emparejamiento guardado, o `null` si no hay (o si iOS borró algo y ya no se puede usar). */
  async loadPairing(): Promise<StoredPairing | null> {
    const record = await this.#db.run((db) => getValue<PairingRecord>(db, "keys", PAIRING));
    if (!record) return null;
    const keys = await this.#unwrapAll(record);
    if (!keys) return null;
    return { mac: record.mac, presence: record.presence, deviceName: record.deviceName, pairedAt: record.pairedAt, keys };
  }

  /** `true` si hay un emparejamiento guardado (aunque no se pueda abrir: "este dispositivo perdió el vínculo"). */
  async hasPairing(): Promise<boolean> {
    return (await this.#db.run((db) => getValue(db, "keys", PAIRING))) !== undefined;
  }

  /** Solo lo que necesita el service worker para descifrar un push. */
  async pushKeys(): Promise<PushKeys | null> {
    const record = await this.#db.run((db) => getValue<PairingRecord>(db, "keys", PAIRING));
    const wrapKey = await this.#wrapKey(false);
    if (!record || !wrapKey) return null;
    const devicePush = await this.#unwrap(wrapKey, "push", record.wrapped.push);
    if (!devicePush) return null;
    return { devicePush, macSeal: record.mac.macSeal, account: record.mac.accountId, device: record.mac.deviceId };
  }

  /** Desemparejar o revocado: borra el emparejamiento y la clave de envoltura (la próxima vez se crea otra). */
  async clear(): Promise<void> {
    await this.#db.run((db) => write(db, ["keys"], (store) => store("keys").clear()));
  }

  close(): void {
    this.#db.close();
  }

  async #wrapKey(create: boolean): Promise<CryptoKey | null> {
    const existing = await this.#db.run((db) => getValue<CryptoKey>(db, "keys", WRAP_KEY));
    if (existing || !create) return existing ?? null;
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    await this.#db.run((db) => write(db, ["keys"], (store) => store("keys").put(key, WRAP_KEY)));
    return key;
  }

  async #unwrap(wrapKey: CryptoKey, name: string, wrapped: WrappedKey): Promise<Bytes | null> {
    try {
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: Uint8Array.from(wrapped.iv),
                                                  additionalData: aad(name) }, wrapKey, wrapped.ciphertext);
      return new Uint8Array(plain);
    } catch {
      return null;
    }
  }

  async #unwrapAll(record: PairingRecord): Promise<DeviceKeys | null> {
    const wrapKey = await this.#wrapKey(false);
    if (!wrapKey) return null;
    const out: Partial<DeviceKeys> = {};
    for (const name of KEY_NAMES) {
      const key = await this.#unwrap(wrapKey, name, record.wrapped[name]);
      if (!key) return null;
      out[name] = key;
    }
    return out as DeviceKeys;
  }
}

/** Pide que el navegador no borre los datos de la app (W.3; se llama al emparejar). */
export async function requestPersistentStorage(): Promise<boolean> {
  try {
    return (await navigator.storage?.persist?.()) ?? false;
  } catch {
    return false;
  }
}

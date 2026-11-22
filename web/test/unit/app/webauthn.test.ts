import { p256 } from "@noble/curves/nist.js";
import { describe, expect, it } from "vitest";
import { concat } from "../../../src/crypto/bytes";
import {
  authDataFromAttestation, coseToSPKI, createPasskey, decodeCBOR, parseAttestedCredential, passkeyAuthorizer,
  PresenceCancelled, PresenceUnavailable, type CredentialsAPI,
} from "../../../src/presence/webauthn";

// CBOR mínimo para armar lo que manda un autenticador.
function head(major: number, n: number): Uint8Array {
  if (n < 24) return Uint8Array.of((major << 5) | n);
  if (n < 256) return Uint8Array.of((major << 5) | 24, n);
  return Uint8Array.of((major << 5) | 25, n >> 8, n & 0xff);
}
function cbor(value: number | string | Uint8Array | Map<number | string, unknown>): Uint8Array {
  if (typeof value === "number") return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (typeof value === "string") {
    const b = new TextEncoder().encode(value);
    return concat(head(3, b.length), b);
  }
  if (value instanceof Uint8Array) return concat(head(2, value.length), value);
  const parts: Uint8Array[] = [head(5, value.size)];
  for (const [k, v] of value) parts.push(cbor(k), cbor(v as never));
  return concat(...parts);
}

function keyPair() {
  const secret = p256.utils.randomSecretKey();
  const point = p256.getPublicKey(secret, false); // 04 ‖ x ‖ y
  const cose = cbor(new Map<number, unknown>([[1, 2], [3, -7], [-1, 1], [-2, point.slice(1, 33)], [-3, point.slice(33)]]));
  return { point, cose };
}

function authData(credentialId: Uint8Array, cose: Uint8Array): Uint8Array {
  const rpIdHash = new Uint8Array(32).fill(7);
  return concat(rpIdHash, Uint8Array.of(0x45), new Uint8Array(4), new Uint8Array(16),
                Uint8Array.of(credentialId.length >> 8, credentialId.length & 0xff), credentialId, cose);
}

const buffer = (b: Uint8Array) => b.slice().buffer;

describe("WebAuthn", () => {
  it("CBOR: enteros, textos, bytes y mapas", () => {
    const { value } = decodeCBOR(cbor(new Map<number | string, unknown>([["a", 1], [-2, new Uint8Array([9])], [500, "x"]])));
    expect(value).toEqual(new Map<unknown, unknown>([["a", 1], [-2, new Uint8Array([9])], [500, "x"]]));
    expect(() => decodeCBOR(Uint8Array.of(0x5f))).toThrow();
    expect(() => decodeCBOR(Uint8Array.of(0x58, 10, 1))).toThrow();
  });

  it("clave COSE → SPKI que WebCrypto acepta", async () => {
    const { point, cose } = keyPair();
    const spki = coseToSPKI(cose);
    const key = await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
    expect(new Uint8Array(await crypto.subtle.exportKey("raw", key))).toEqual(point);
    const rsa = cbor(new Map<number, unknown>([[1, 3], [3, -257]]));
    expect(() => coseToSPKI(rsa)).toThrow();
  });

  it("saca la credencial de authenticatorData y del attestationObject", () => {
    const { cose } = keyPair();
    const id = Uint8Array.from([1, 2, 3, 4]);
    const data = concat(authData(id, cose), cbor(new Map<string, unknown>([["credProtect", 2]])));
    const parsed = parseAttestedCredential(data);
    expect(parsed.credentialId).toEqual(id);
    expect(parsed.cose).toEqual(cose);
    const attestation = cbor(new Map<string, unknown>([["fmt", "none"], ["attStmt", new Map()], ["authData", data]]));
    expect(authDataFromAttestation(attestation)).toEqual(data);
  });

  it("crea la passkey (W.4.6) con getPublicKey o, si falta, desde COSE", async () => {
    const { point, cose } = keyPair();
    const id = Uint8Array.from([9, 9, 9]);
    const spki = coseToSPKI(cose);
    let options: CredentialCreationOptions | undefined;
    const make = (withGetPublicKey: boolean): CredentialsAPI => ({
      async create(o) {
        options = o;
        const attestationObject = cbor(new Map<string, unknown>([["fmt", "none"], ["attStmt", new Map()],
                                                                 ["authData", authData(id, cose)]]));
        return {
          id: "x", type: "public-key", rawId: buffer(id),
          response: {
            attestationObject: buffer(attestationObject),
            ...(withGetPublicKey ? { getPublicKey: () => buffer(spki) } : {}),
          },
        } as unknown as Credential;
      },
      async get() {
        return null;
      },
    });
    for (const withKey of [true, false]) {
      const credential = await createPasskey({ rpId: "relay.example.com", userName: "PRBar · iPhone", credentials: make(withKey) });
      expect(credential.rpId).toBe("relay.example.com");
      expect(credential.credentialId).toEqual(id);
      expect(credential.publicKey).toEqual(spki);
    }
    const pk = options!.publicKey!;
    expect(pk.rp).toEqual({ id: "relay.example.com", name: "PRBar" });
    expect(pk.pubKeyCredParams).toEqual([{ type: "public-key", alg: -7 }]);
    expect(pk.authenticatorSelection).toMatchObject({ authenticatorAttachment: "platform", residentKey: "required",
                                                      userVerification: "required" });
    expect(pk.attestation).toBe("none");
    expect((pk.user.id as Uint8Array).length).toBe(16);
    expect(point.length).toBe(65);
  });

  it("cancelar o no tener WebAuthn", async () => {
    const cancel: CredentialsAPI = {
      async create() {
        throw Object.assign(new Error("no"), { name: "NotAllowedError" });
      },
      async get() {
        throw Object.assign(new Error("no"), { name: "NotAllowedError" });
      },
    };
    await expect(createPasskey({ rpId: "r", userName: "u", credentials: cancel })).rejects.toBeInstanceOf(PresenceCancelled);
    await expect(createPasskey({ rpId: "r", userName: "u", credentials: null })).rejects.toBeInstanceOf(PresenceUnavailable);
    const credential = { credentialId: new Uint8Array([1]), publicKey: new Uint8Array(91), rpId: "r" };
    await expect(passkeyAuthorizer(credential, cancel)(new Uint8Array(32))).rejects.toBeInstanceOf(PresenceCancelled);
    const broken: CredentialsAPI = { ...cancel, async get() { throw Object.assign(new Error("locked"), { name: "InvalidStateError" }); } };
    await expect(passkeyAuthorizer(credential, broken)(new Uint8Array(32))).rejects.toThrow("locked");
  });

  it("firma el desafío con la credencial guardada (W.5)", async () => {
    let request: CredentialRequestOptions | undefined;
    const api: CredentialsAPI = {
      async create() {
        return null;
      },
      async get(o) {
        request = o;
        return {
          rawId: buffer(Uint8Array.of(1)),
          response: { authenticatorData: buffer(Uint8Array.of(2)), clientDataJSON: buffer(Uint8Array.of(3)),
                      signature: buffer(Uint8Array.of(4)) },
        } as unknown as Credential;
      },
    };
    const challenge = new Uint8Array(32).fill(5);
    const assertion = await passkeyAuthorizer({ credentialId: Uint8Array.of(1), publicKey: new Uint8Array(91), rpId: "relay.example.com" }, api)(challenge);
    expect(assertion).toEqual({ credentialId: Uint8Array.of(1), authenticatorData: Uint8Array.of(2),
                                clientDataJSON: Uint8Array.of(3), signature: Uint8Array.of(4) });
    expect(request!.publicKey).toMatchObject({ rpId: "relay.example.com", userVerification: "required", challenge });
    expect(request!.publicKey!.allowCredentials).toEqual([{ type: "public-key", id: Uint8Array.of(1) }]);
  });
});

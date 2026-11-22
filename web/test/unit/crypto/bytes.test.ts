import { describe, expect, it } from "vitest";
import { b64Decode, b64Encode, b64urlDecode, b64urlEncode } from "../../../src/crypto/b64";
import { concat, constantTimeEqual, fromHex, i64BE, readU32BE, toHex, u32BE, u64BE, utf8 } from "../../../src/crypto/bytes";

describe("bytes", () => {
  it("hex ida y vuelta, rechaza hex inválido", () => {
    expect(toHex(fromHex("00ff10Ab"))).toBe("00ff10ab");
    expect(() => fromHex("abc")).toThrow();
    expect(() => fromHex("zz")).toThrow();
  });

  it("enteros big endian como Data(uint64BE:) / Data(int64BE:) de Swift", () => {
    expect(toHex(u64BE(1n))).toBe("0000000000000001");
    expect(toHex(u64BE(0x0102030405060708n))).toBe("0102030405060708");
    expect(toHex(u64BE(2 ** 53 - 1))).toBe("001fffffffffffff");
    expect(toHex(u64BE(0xffffffffffffffffn))).toBe("ffffffffffffffff");
    expect(() => u64BE(-1)).toThrow();
    expect(() => u64BE(2n ** 64n)).toThrow();
    expect(toHex(i64BE(-1))).toBe("ffffffffffffffff");
    expect(toHex(i64BE(1_800_000_000_000))).toBe("000001a3185c5000");
    expect(toHex(u32BE(0x01020304))).toBe("01020304");
    expect(readU32BE(fromHex("ff01020304"), 1)).toBe(0x01020304);
    expect(readU32BE(fromHex("ffffffff"), 0)).toBe(0xffffffff);
  });

  it("concat y utf8", () => {
    expect(toHex(concat(utf8("a"), new Uint8Array([0]), utf8("ñ")))).toBe("6100c3b1");
  });

  it("comparación en tiempo constante", () => {
    expect(constantTimeEqual(fromHex("0102"), fromHex("0102"))).toBe(true);
    expect(constantTimeEqual(fromHex("0102"), fromHex("0103"))).toBe(false);
    expect(constantTimeEqual(fromHex("0102"), fromHex("01"))).toBe(false);
  });
});

describe("base64url (estricto, como Base64URL.swift)", () => {
  it("codifica sin relleno", () => {
    expect(b64urlEncode(new Uint8Array([]))).toBe("");
    expect(b64urlEncode(fromHex("fb"))).toBe("-w");
    expect(b64urlEncode(fromHex("fbff"))).toBe("-_8");
    expect(b64urlEncode(fromHex("fbffbf"))).toBe("-_-_");
    expect(b64urlEncode(utf8("hello world"))).toBe("aGVsbG8gd29ybGQ");
  });

  it("decodifica ida y vuelta", () => {
    for (let n = 0; n < 40; n++) {
      const data = Uint8Array.from({ length: n }, (_, i) => (i * 37 + n) & 0xff);
      expect(b64urlDecode(b64urlEncode(data))).toEqual(data);
    }
  });

  it("rechaza relleno, +, /, espacios, largos imposibles y bits sobrantes", () => {
    for (const bad of ["aGVsbG8=", "a+b/", "aGVs bG8", "a", "aGVsb", "-x", "-_9", "é"]) {
      expect(() => b64urlDecode(bad), bad).toThrow();
    }
  });
});

describe("base64 estándar (campo `e` del push)", () => {
  it("ida y vuelta con relleno", () => {
    expect(b64Encode(fromHex("fbff"))).toBe("+/8=");
    expect(b64Decode("+/8=")).toEqual(fromHex("fbff"));
    expect(() => b64Decode("+/8")).toThrow();
    expect(() => b64Decode("-_8=")).toThrow();
  });
});

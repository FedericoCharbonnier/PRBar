// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { cleanup, fireEvent, render } from "@testing-library/preact";
import { createRef } from "preact";
import { afterEach, describe, expect, it } from "vitest";
import { PageContext } from "../../../src/ui/nav/context";
import { isNearBottom } from "../../../src/ui/nav/stickToBottom";
import { Chat } from "../../../src/ui/screens";
import type { ChatItemVM } from "../../../src/ui/screens";
import { hiddenByKeyboard, keyboardInset, KEYBOARD_EVENT } from "../../../src/ui/viewport";

afterEach(cleanup);

describe("keyboardInset (teclado de iOS)", () => {
  it("sin teclado: 0", () => {
    expect(keyboardInset({ innerHeight: 844, height: 844, offsetTop: 0 })).toBe(0);
  });

  it("con el teclado: lo que tapa abajo, descontando lo que Safari corrió la vista", () => {
    expect(keyboardInset({ innerHeight: 844, height: 508, offsetTop: 0 })).toBe(336);
    expect(keyboardInset({ innerHeight: 844, height: 508, offsetTop: 120 })).toBe(216);
  });

  it("diferencias chicas (redondeos) y el zoom de pellizco no son teclado", () => {
    expect(keyboardInset({ innerHeight: 844, height: 843.5, offsetTop: 0 })).toBe(0);
    expect(keyboardInset({ innerHeight: 844, height: 422, offsetTop: 0, scale: 2 })).toBe(0);
  });

  it("un campo debajo del borde del teclado está tapado", () => {
    expect(hiddenByKeyboard({ bottom: 700 }, 844, 336)).toBe(true);
    expect(hiddenByKeyboard({ bottom: 400 }, 844, 336)).toBe(false);
    expect(hiddenByKeyboard({ bottom: 840 }, 844, 0)).toBe(false);
  });
});

describe("isNearBottom", () => {
  it("abajo de todo o a menos de 80 px", () => {
    expect(isNearBottom({ scrollTop: 1000, scrollHeight: 1600, clientHeight: 600 })).toBe(true);
    expect(isNearBottom({ scrollTop: 930, scrollHeight: 1600, clientHeight: 600 })).toBe(true);
    expect(isNearBottom({ scrollTop: 500, scrollHeight: 1600, clientHeight: 600 })).toBe(false);
  });
});

describe("Chat: se queda en el último mensaje", () => {
  /** Un scroller con alto de contenido de mentira (happy-dom no calcula layout): 100 px por mensaje. */
  function setup(items: ChatItemVM[]) {
    const scroller = createRef<HTMLDivElement>();
    const host = document.createElement("div");
    document.body.appendChild(host);
    let height = 0;
    const view = (list: ChatItemVM[], typing = false) => (
      <div ref={(el) => {
        scroller.current = el;
        if (el && !Object.getOwnPropertyDescriptor(el, "scrollHeight")) {
          Object.defineProperty(el, "scrollHeight", { get: () => height });
          Object.defineProperty(el, "clientHeight", { get: () => 600 });
        }
      }}>
        <PageContext.Provider value={{ scroller, visible: true }}>
          <Chat context="api#317 · Review" readOnly={false} items={list} draft="hola" placeholder="Message Claude"
                typing={typing} onBack={() => {}} onDraft={() => {}} onSend={() => {}} onUndo={() => {}} />
        </PageContext.Provider>
      </div>
    );
    height = items.length * 100;
    const result = render(view(items), { container: host });
    return {
      scroller,
      update(list: ChatItemVM[], typing = false) {
        height = list.length * 100;
        result.rerender(view(list, typing));
      },
    };
  }

  const msgs = (n: number, last = "ok"): ChatItemVM[] =>
    Array.from({ length: n }, (_, i) => ({ kind: i % 2 ? "claude" : "mine", id: `m${i}`, text: i === n - 1 ? last : `m${i}` }));

  it("abre abajo y sigue los mensajes nuevos y la respuesta que llega", () => {
    const t = setup(msgs(20));
    const el = t.scroller.current!;
    expect(el.scrollTop).toBe(2000);
    t.update(msgs(21));
    expect(el.scrollTop).toBe(2100);
    // Un pedazo más de la respuesta (mismo número de mensajes, más texto) también.
    t.update(msgs(22, "a"));
    t.update(msgs(22, "a longer streaming answer"));
    expect(el.scrollTop).toBe(2200);
  });

  it("si el usuario subió a leer, no lo mueve; al mandar, sí baja", () => {
    const t = setup(msgs(20));
    const el = t.scroller.current!;
    el.scrollTop = 300;
    el.dispatchEvent(new Event("scroll"));
    t.update(msgs(21));
    expect(el.scrollTop).toBe(300);
    fireEvent.submit(el.querySelector("form")!);
    t.update(msgs(22));
    expect(el.scrollTop).toBe(2200);
  });

  it("al abrirse el teclado, si estaba abajo, sigue abajo", () => {
    const t = setup(msgs(20));
    const el = t.scroller.current!;
    el.scrollTop = 1000;
    window.dispatchEvent(new Event(KEYBOARD_EVENT));
    expect(el.scrollTop).toBe(2000);
  });
});

describe("campos de texto", () => {
  it("todos con letra de 16 px o más (si no, iOS hace zoom al tocarlos)", () => {
    const css = ["src/ui/screens/screens.css", "src/ui/components/components.css"]
      .map((p) => readFileSync(join(process.cwd(), p), "utf8")).join("\n");
    for (const selector of [".field__input", ".paste__input", ".composer__input", ".edit__editor"]) {
      const rule = css.match(new RegExp(`\\${selector} \\{([^}]*)\\}`))?.[1] ?? "";
      const size = Number(rule.match(/font-size:\s*(\d+)px/)?.[1]);
      expect(size, selector).toBeGreaterThanOrEqual(16);
    }
  });
});

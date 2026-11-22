// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/preact";
import { createRef } from "preact";
import { afterEach, describe, expect, it } from "vitest";
import { Sheet } from "../../../src/ui/components";
import { PageContext } from "../../../src/ui/nav/context";

afterEach(() => {
  cleanup();
  document.getElementById("overlay-root")?.remove();
});

function page(visible: boolean) {
  return (
    <PageContext.Provider value={{ scroller: createRef(), visible }}>
      <Sheet detent="medium" label="Edit Comment" onDismiss={() => {}}>
        <p>Inside</p>
      </Sheet>
    </PageContext.Provider>
  );
}

describe("Sheet", () => {
  it("el fondo queda inerte y el foco va a la hoja; al cerrar vuelve", () => {
    const app = document.createElement("div");
    app.id = "app";
    document.body.appendChild(app);
    const behind = document.createElement("button");
    app.appendChild(behind);
    behind.focus();
    const host = document.createElement("div");
    document.body.appendChild(host);
    const { rerender } = render(page(true), { container: host });
    const dialog = screen.getByRole("dialog", { name: "Edit Comment" });
    expect(document.activeElement).toBe(dialog);
    expect(behind.hasAttribute("inert")).toBe(true);
    rerender(<div />);
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(behind.hasAttribute("inert")).toBe(false);
    expect(document.activeElement).toBe(behind);
    app.remove();
    host.remove();
  });

  it("la hoja de una pantalla tapada se cierra (no queda encima de la nueva) y vuelve al volver", () => {
    const { rerender } = render(page(true));
    expect(screen.getByText("Inside")).toBeTruthy();
    rerender(page(false));
    expect(screen.queryByText("Inside")).toBeNull();
    rerender(page(true));
    expect(screen.getByText("Inside")).toBeTruthy();
  });
});

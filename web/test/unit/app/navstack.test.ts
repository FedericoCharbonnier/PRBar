import { describe, expect, it } from "vitest";
import {
  chainFor, currentStack, initialNav, navigate, pop, popToRoot, push, replaceTop, routeTitle, selectTab, topRoute,
  type NavState, type StackRoute,
} from "../../../src/app/navstack";
import { HOME, routeHash } from "../../../src/app/router";

const mine = (pr: string) => pr === "acme/api#322";
const review: StackRoute = { kind: "pr", pr: "acme/api#317", screen: "review" };
const chat: StackRoute = { kind: "pr", pr: "acme/api#317", screen: "chat", chat: "review" };
const merge: StackRoute = { kind: "pr", pr: "acme/api#322", screen: "merge" };
const hashes = (state: NavState) => currentStack(state).map(routeHash);

describe("pila de navegación", () => {
  it("arranca con la raíz de cada pestaña, o con la cadena hasta una ruta profunda", () => {
    const home = initialNav(HOME, mine);
    expect(home.tab).toBe("review");
    expect(Object.values(home.stacks).map((s) => s.length)).toEqual([1, 1, 1, 1]);
    const deep = initialNav(chat, mine);
    expect(deep.tab).toBe("review");
    expect(hashes(deep)).toEqual(["#/home", "#/pr/acme/api/317/review", "#/pr/acme/api/317/chat/review"]);
    expect(initialNav(merge, mine).tab).toBe("mine");
    expect(chainFor(merge, mine).map(routeHash)).toEqual(["#/mine", "#/pr/acme/api/322/merge"]);
  });

  it("push apila y pop vuelve (con su transición)", () => {
    let state = initialNav(HOME, mine);
    let change = push(state, review, mine);
    expect(change.transition).toBe("push");
    state = change.state;
    change = push(state, chat, mine);
    expect(change.transition).toBe("push");
    state = change.state;
    expect(hashes(state)).toHaveLength(3);
    // La misma ruta arriba no se apila dos veces.
    expect(push(state, chat, mine).transition).toBe("none");
    change = pop(state, mine);
    expect(change.transition).toBe("pop");
    expect(topRoute(change.state)).toEqual(review);
    expect(pop(initialNav(HOME, mine), mine).transition).toBe("none");
  });

  it("cada pestaña guarda su pila; tocar la elegida vuelve a la raíz", () => {
    let state = push(initialNav(HOME, mine), review, mine).state;
    const toSettings = selectTab(state, "settings");
    expect(toSettings.transition).toBe("tab");
    state = toSettings.state;
    expect(hashes(state)).toEqual(["#/settings"]);
    state = selectTab(state, "review").state;
    expect(topRoute(state)).toEqual(review);
    const again = selectTab(state, "review");
    expect(again.transition).toBe("pop");
    expect(hashes(again.state)).toEqual(["#/home"]);
    expect(popToRoot(again.state).transition).toBe("none");
  });

  it("una pantalla de PR desde Activity o Settings va a su pestaña", () => {
    const state = selectTab(initialNav(HOME, mine), "activity").state;
    const change = push(state, merge, mine);
    expect(change.transition).toBe("tab");
    expect(change.state.tab).toBe("mine");
    expect(hashes(change.state)).toEqual(["#/mine", "#/pr/acme/api/322/merge"]);
  });

  it("un cambio de hash: pop si está debajo, pestaña si está en otra, push si es nueva", () => {
    let state = push(initialNav(HOME, mine), review, mine).state;
    state = push(state, chat, mine).state;
    const back = navigate(state, review, mine);
    expect(back.transition).toBe("pop");
    expect(hashes(back.state)).toHaveLength(2);
    const root = navigate(state, HOME, mine);
    expect(root.transition).toBe("pop");
    expect(hashes(root.state)).toEqual(["#/home"]);
    const other = navigate(state, { kind: "tab", tab: "mine" }, mine);
    expect(other.transition).toBe("tab");
    expect(other.state.stacks.review).toHaveLength(3);
    // Volver a la pestaña por el hash de una pantalla que está en su pila: se corta ahí.
    const returned = navigate(other.state, review, mine);
    expect(returned.transition).toBe("tab");
    expect(returned.state.tab).toBe("review");
    expect(hashes(returned.state)).toEqual(["#/home", "#/pr/acme/api/317/review"]);
    expect(navigate(state, chat, mine).transition).toBe("none");
    expect(navigate(state, { kind: "pair" }, mine).transition).toBe("none");
  });

  it("replace cambia la de arriba sin animar y arma la cadena si queda sin raíz", () => {
    const state = initialNav(HOME, mine);
    const change = replaceTop(state, chat, mine);
    expect(change.transition).toBe("none");
    expect(hashes(change.state)).toEqual(["#/home", "#/pr/acme/api/317/review", "#/pr/acme/api/317/chat/review"]);
    expect(replaceTop(change.state, { kind: "tab", tab: "settings" }, mine).transition).toBe("tab");
  });

  it("títulos cortos para el botón Back", () => {
    expect(routeTitle(HOME as StackRoute)).toBe("To Review");
    expect(routeTitle({ kind: "tab", tab: "mine" })).toBe("My PRs");
    expect(routeTitle(chat)).toBe("Claude");
    expect(routeTitle({ kind: "pr", pr: "acme/web-app#488" }, "fixci")).toBe("Fix CI");
  });
});

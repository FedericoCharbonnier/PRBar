import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { snapshotName, stories } from "./stories";
import "../ui/tokens.css";
import "../ui/base.css";
import "./stories.css";

// Arnés de historias (solo pruebas, no se publica): `#/<pantalla>?theme=dark|light`.
// El tema se fuerza reescribiendo las reglas `prefers-color-scheme` de las hojas cargadas (CSSOM, sin estilos en línea).

function parse(): { id: string; theme: string | null } {
  const [path = "", query = ""] = location.hash.replace(/^#\/?/, "").split("?");
  return { id: decodeURIComponent(path), theme: new URLSearchParams(query).get("theme") };
}

function forceTheme(theme: string | null) {
  document.documentElement.dataset["theme"] = theme ?? "";
  for (const sheet of Array.from(document.styleSheets)) {
    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      continue;
    }
    for (const rule of Array.from(rules)) {
      if (!(rule instanceof CSSMediaRule)) continue;
      const original = (rule as CSSMediaRule & { _orig?: string })._orig ?? rule.media.mediaText;
      (rule as CSSMediaRule & { _orig?: string })._orig = original;
      if (!original.includes("prefers-color-scheme: dark")) continue;
      rule.media.mediaText = theme === "dark" ? "all" : theme === "light" ? "not all" : original;
    }
  }
}

function Index() {
  return (
    <main class="story-index">
      <h1>PRBar stories</h1>
      <ul>
        {stories.map((s) => (
          <li key={s.id}>
            <a href={`#/${s.id}`}>{s.id}</a> · <a href={`#/${s.id}?theme=dark`}>dark</a>
            <small> {snapshotName(s.id)}</small>
          </li>
        ))}
      </ul>
    </main>
  );
}

function Harness() {
  const [route, setRoute] = useState(parse);
  useEffect(() => {
    const on = () => setRoute(parse());
    addEventListener("hashchange", on);
    return () => removeEventListener("hashchange", on);
  }, []);
  useEffect(() => {
    forceTheme(route.theme);
    document.documentElement.dataset["story"] = route.id;
  }, [route]);
  const story = stories.find((s) => s.id === route.id);
  return story ? story.render() : <Index />;
}

const root = document.getElementById("app");
if (root) render(<Harness />, root);

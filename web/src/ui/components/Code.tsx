import { Icon } from "./Icon";
import { DiffCount } from "./basics";
import type { CheckLogLine, CodeLineVM, DiffLineVM } from "../screens/types";
import "./components.css";

// Bloques de código: extracto con números de línea, log de CI y diff unificado con scroll horizontal.

export function CodeBlock({ lines }: { lines: CodeLineVM[] }) {
  return (
    <pre class="code-block">
      {lines.map((l) => (
        <span key={l.number} class={l.highlight ? "code-line code-line--hl" : "code-line"}>
          <span class="code-line__no">{l.number}</span>
          <span class="code-line__text">{l.text}</span>
        </span>
      ))}
    </pre>
  );
}

export function LogBlock({ lines }: { lines: CheckLogLine[] }) {
  return (
    <pre class="log-block">
      {lines.map((l, i) => (
        <span key={i} class={`log-line log-line--${l.tone}`}>
          {l.text}
        </span>
      ))}
    </pre>
  );
}

export function DiffView({ path, additions, deletions, lines }: {
  path: string; additions: number; deletions: number; lines: DiffLineVM[];
}) {
  return (
    <div class="diff">
      <div class="diff__header">
        <Icon name="doc.text" size={20} />
        <span class="diff__path">{path}</span>
        <DiffCount additions={additions} deletions={deletions} />
      </div>
      <div class="diff__scroll" role="group" aria-label="Diff, scrolls horizontally" tabIndex={0}>
        <div class="diff__lines">
          {lines.map((l, i) => (
            <div key={i} class={`diff-line diff-line--${l.kind}`}>
              <span class="diff-line__no">{l.kind === "hunk" ? "" : l.number}</span>
              <span class="diff-line__sign">{l.kind === "add" ? "+" : l.kind === "del" ? "−" : ""}</span>
              <span class="diff-line__text">{l.text}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

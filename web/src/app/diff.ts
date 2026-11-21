import type { DiffFileVM, DiffLineVM } from "../ui/screens/types";

// Un diff unificado partido en archivos y líneas para `respond:diff` (UnifiedDiff.swift).

export interface DiffFile extends DiffFileVM {
  sensitive: boolean;
}

/** `@@ -52,10 +52,15 @@ …` → [52, 52]. */
export function hunkStarts(header: string): [number, number] {
  const parts = header.split(" ");
  const start = (prefix: string) => {
    const part = parts.find((p) => p.startsWith(prefix));
    return part ? Number(part.slice(1).split(",")[0]) || 0 : 0;
  };
  return [start("-"), start("+")];
}

const SKIP = ["--- ", "+++ ", "index ", "new file", "deleted file", "similarity", "rename ", "\\ No newline"];

export function parseUnifiedDiff(text: string, sensitive: string[] = []): DiffFile[] {
  const files: DiffFile[] = [];
  let current: DiffFile | null = null;
  let oldLine = 0;
  let newLine = 0;
  for (const line of text.split("\n")) {
    if (line.startsWith("diff --git ")) {
      if (current) files.push(current);
      const path = line.split(" b/").pop() ?? line;
      current = {
        id: path, path, name: path.split("/").pop() || path, additions: 0, deletions: 0, lines: [],
        sensitive: sensitive.some((s) => path.endsWith(s) || s.endsWith(path)),
      };
      continue;
    }
    if (!current) continue;
    if (SKIP.some((prefix) => line.startsWith(prefix))) continue;
    let entry: DiffLineVM;
    if (line.startsWith("@@")) {
      [oldLine, newLine] = hunkStarts(line);
      entry = { kind: "hunk", text: line };
    } else if (line.startsWith("+")) {
      current.additions++;
      entry = { kind: "add", number: newLine++, text: line.slice(1) };
    } else if (line.startsWith("-")) {
      current.deletions++;
      entry = { kind: "del", number: oldLine++, text: line.slice(1) };
    } else {
      // Una línea vacía al final del texto no es contexto.
      if (line === "") continue;
      entry = { kind: "context", number: newLine, text: line.slice(1) };
      oldLine++;
      newLine++;
    }
    current.lines.push(entry);
  }
  if (current) files.push(current);
  return files;
}

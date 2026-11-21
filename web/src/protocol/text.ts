// Texto que cruza entre la Mac y el teléfono y que pudo escribir otro (nombres de un link de emparejamiento, títulos
// de un push): se muestra plano, sin escapes de terminal ni caracteres invisibles que reordenan u ocultan lo que se
// ve (bidi, ancho cero). Copia de RemoteText.swift (revisión M1/L1/L5).

const ANSI = /(?:\u001b\[|\u009b)[0-?]*[ -/]*[@-~]|(?:\u001b\]|\u009d)[^\u0007\u001b]*(?:\u0007|\u001b\\)?|\u001b[@-Z\\-_]/g;
const DROP = /[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}]/u;

/** Texto de varias líneas: sin escapes ANSI, `\r\n`/`\r` como `\n`, sin controles salvo `\n` y `\t`, sin caracteres
 *  de formato salvo el ZWJ de los emoji, y como mucho un selector de variación después de algo visible. */
export function cleanText(input: string): string {
  let text = input.replace(/\r\n?/g, "\n");
  text = text.replace(ANSI, "");
  let out = "";
  let previousWasSelector = true;
  for (const ch of text) {
    const code = ch.codePointAt(0)!;
    const vs16 = code >= 0xfe00 && code <= 0xfe0f;
    const supplementary = code >= 0xe0100 && code <= 0xe01ef;
    if (vs16 || supplementary) {
      if (vs16 && !previousWasSelector) out += ch;
      previousWasSelector = true;
      continue;
    }
    previousWasSelector = false;
    if (ch === "\n" || ch === "\t" || code === 0x200d) out += ch;
    else if (code === 0x2028 || code === 0x2029) out += "\n";
    else if (!DROP.test(ch)) out += ch;
  }
  return out;
}

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Un nombre o un título: una línea, sin controles, como mucho `limit` caracteres (grafemas). Vacío si no queda nada
 *  visible. */
export function displayName(input: string, limit = 64): string {
  const oneLine = cleanText(input).split(/[\n\t ]+/).filter((part) => part.length > 0).join(" ");
  let out = "";
  let count = 0;
  for (const { segment } of segmenter.segment(oneLine)) {
    if (count++ >= limit) break;
    out += segment;
  }
  return out.trim();
}

import type { JSX } from "preact";

// Íconos en SVG en línea que imitan los SF Symbols del diseño (sin fuentes de íconos ni nada externo).
// Todos usan `currentColor`; los de trazo van con extremos redondeados como los símbolos de Apple.

const S = { fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round" } as const;
const F = { fill: "currentColor" } as const;

const paths = {
  "chevron.left": () => <path {...S} stroke-width={2.4} d="M15 4.5 7.5 12l7.5 7.5" />,
  "chevron.right": () => <path {...S} stroke-width={2.2} d="M9 4.5 16.5 12 9 19.5" />,
  "chevron.down": () => <path {...S} stroke-width={2.2} d="M4.5 9 12 16.5 19.5 9" />,
  "chevron.up.chevron.down": () => <path {...S} stroke-width={2} d="M7.5 9 12 4.5 16.5 9M7.5 15l4.5 4.5 4.5-4.5" />,
  xmark: () => <path {...S} stroke-width={2.4} d="M5.5 5.5l13 13M18.5 5.5l-13 13" />,
  checkmark: () => <path {...S} stroke-width={2.6} d="M4.5 12.5 9.5 17.5 19.5 6.5" />,
  ellipsis: () => (
    <g {...F}>
      <circle cx="5" cy="12" r="2" />
      <circle cx="12" cy="12" r="2" />
      <circle cx="19" cy="12" r="2" />
    </g>
  ),
  "line.3.horizontal.decrease": () => <path {...S} stroke-width={2.4} d="M3.5 6.5h17M6.5 12h11M9.5 17.5h5" />,
  laptopcomputer: () => (
    <g>
      <rect x="4" y="5" width="16" height="11" rx="1.6" fill="currentColor" fill-opacity="0.3" />
      <path {...S} stroke-width={1.9} d="M5.6 5h12.8c.9 0 1.6.7 1.6 1.6V16H4V6.6C4 5.7 4.7 5 5.6 5ZM1.5 18.6h21" />
    </g>
  ),
  terminal: () => (
    <g {...S} stroke-width={1.6}>
      <rect x="3" y="5" width="18" height="14" rx="2.5" />
      <path d="m6.5 9 2.5 2-2.5 2M10.5 13.5h3" />
    </g>
  ),
  "exclamationmark.triangle.fill": () => (
    <g>
      <path {...F} d="M10.3 3.6a2 2 0 0 1 3.4 0l8.4 14.6A2 2 0 0 1 20.4 21H3.6a2 2 0 0 1-1.7-2.8Z" />
      <path class="ko-s" stroke-width={2.2} stroke-linecap="round" d="M12 8.5v5.5" />
      <circle cx="12" cy="17.4" r="1.3" class="ko-f" />
    </g>
  ),
  "exclamationmark.triangle": () => (
    <g {...S} stroke-width={1.8}>
      <path d="M10.3 4.1a2 2 0 0 1 3.4 0l7.9 13.8a2 2 0 0 1-1.7 3H4.1a2 2 0 0 1-1.7-3Z" />
      <path d="M12 9v4.5M12 17v.1" />
    </g>
  ),
  "checkmark.circle.fill": () => (
    <g>
      <circle cx="12" cy="12" r="10" {...F} />
      <path fill="none" class="ko-s" stroke-width={2.4} stroke-linecap="round" stroke-linejoin="round" d="m7.5 12.3 3 3 6-6.6" />
    </g>
  ),
  "checkmark.circle": () => (
    <g {...S} stroke-width={1.9}>
      <circle cx="12" cy="12" r="9.5" />
      <path d="m7.8 12.3 2.9 2.9 5.6-6.2" />
    </g>
  ),
  "xmark.octagon.fill": () => (
    <g>
      <circle cx="12" cy="12" r="10" {...F} />
      <path fill="none" class="ko-s" stroke-width={2.2} stroke-linecap="round" d="m8.6 8.6 6.8 6.8M15.4 8.6l-6.8 6.8" />
    </g>
  ),
  "text.bubble": () => (
    <g {...S} stroke-width={1.8}>
      <path d="M5 3.8h14a2.2 2.2 0 0 1 2.2 2.2v9a2.2 2.2 0 0 1-2.2 2.2h-6.5L8 21v-3.8H5A2.2 2.2 0 0 1 2.8 15V6A2.2 2.2 0 0 1 5 3.8Z" />
      <path d="M7 8.3h10M7 12.2h7" />
    </g>
  ),
  "bubble.left.and.bubble.right": () => (
    <g {...S} stroke-width={1.8}>
      <path d="M4.5 3.5h9.5a2.5 2.5 0 0 1 2.5 2.5v5a2.5 2.5 0 0 1-2.5 2.5H8.8L5.5 16v-2.5h-1A2.5 2.5 0 0 1 2 11V6a2.5 2.5 0 0 1 2.5-2.5Z" />
      <path d="M16.5 8h3a2.5 2.5 0 0 1 2.5 2.5v5a2.5 2.5 0 0 1-2.5 2.5h-1V20.5L15.2 18H10a2.5 2.5 0 0 1-2.5-2.5v-.3" />
    </g>
  ),
  sparkles: () => (
    <g {...F}>
      <path d="M13 6.5c.5 3.8 1.9 5.3 5.6 5.8-3.7.5-5.1 2-5.6 5.8-.5-3.8-1.9-5.3-5.6-5.8 3.7-.5 5.1-2 5.6-5.8Z" />
      <path d="M6.4 2.5c.25 1.7.85 2.3 2.5 2.55-1.65.25-2.25.85-2.5 2.55-.25-1.7-.85-2.3-2.5-2.55 1.65-.25 2.25-.85 2.5-2.55Z" />
      <path d="M6 16.5c.2 1.2.6 1.6 1.8 1.8-1.2.2-1.6.6-1.8 1.8-.2-1.2-.6-1.6-1.8-1.8 1.2-.2 1.6-.6 1.8-1.8Z" />
    </g>
  ),
  pencil: () => (
    <g>
      <path {...S} stroke-width={2.6} d="M7.6 16.4 17.6 6.4" />
      <path {...F} d="M4.4 19.6 5.6 15.2l3.2 3.2Z" />
    </g>
  ),
  faceid: () => (
    <g {...S} stroke-width={1.8}>
      <path d="M3 8V6a3 3 0 0 1 3-3h2M16 3h2a3 3 0 0 1 3 3v2M21 16v2a3 3 0 0 1-3 3h-2M8 21H6a3 3 0 0 1-3-3v-2" />
      <path d="M8.5 9v1.3M15.5 9v1.3M12 9v3.5h-1M9 16c1.7 1.3 4.3 1.3 6 0" />
    </g>
  ),
  "arrow.up.right": () => <path {...S} stroke-width={2.4} d="M7 17 17 7M8.5 7H17v8.5" />,
  "arrow.uturn.backward": () => <path {...S} stroke-width={2.2} d="M9 14 4.5 9.5 9 5M5 9.5h9.5a5 5 0 0 1 0 10H12" />,
  "stop.fill": () => <rect x="5" y="5" width="14" height="14" rx="2" {...F} />,
  "doc.text": () => (
    <g {...S} stroke-width={1.6}>
      <path d="M6.5 2.8h7.2l4.8 4.8v11.6a2 2 0 0 1-2 2h-10a2 2 0 0 1-2-2V4.8a2 2 0 0 1 2-2Z" />
      <path d="M13.5 3v4.8h4.8M8.5 12.5h7M8.5 16h7" />
    </g>
  ),
  checklist: () => (
    <g>
      <circle cx="5.5" cy="7" r="2.6" {...F} />
      <path fill="none" class="ko-s" stroke-width={1.3} stroke-linecap="round" stroke-linejoin="round" d="m4.3 7 .9.9 1.6-1.7" />
      <circle cx="5.5" cy="17" r="2.6" {...S} stroke-width={1.5} />
      <path {...S} stroke-width={1.6} d="M11 7h10M11 17h10" />
    </g>
  ),
  number: () => <path {...S} stroke-width={1.6} d="M9.5 3.5 7.5 20.5M16.5 3.5l-2 17M4 8.5h16.5M3.5 15.5H20" />,
  "arrow.triangle.merge": () => <path {...S} stroke-width={2.4} d="M12 3.5v9.5M8.3 7.2 12 3.5l3.7 3.7M12 13c0 2.6-1.6 4.3-4.2 6.5M12 13c0 2.6 1.6 4.3 4.2 6.5" />,
  prbar: () => <path {...S} stroke-width={2.4} d="M9.5 21V4M5.8 7.8 9.5 3.5l3.7 4.3M9.5 13.5c0 2.4 1.8 3.8 4.8 5.3" />,
  "arrow.up": () => <path {...S} stroke-width={2.4} d="M12 20V4.5M5.5 11 12 4.5l6.5 6.5" />,
  "arrow.right": () => <path {...S} stroke-width={1.8} d="M4 12h15.5M13.5 6l6 6-6 6" />,
  "arrow.clockwise": () => <path {...S} stroke-width={2} d="M19.5 12a7.5 7.5 0 1 1-2.4-5.5M17.5 2.8v4h-4" />,
  "lock.fill": () => (
    <g {...F}>
      <rect x="5" y="10.5" width="14" height="11" rx="2.2" />
      <path {...S} stroke-width={2} d="M8 10.5V7.5a4 4 0 0 1 8 0v3" />
    </g>
  ),
  "lock.shield": () => (
    <g>
      <path {...S} stroke-width={1.9} d="M12 2.5 4.5 5.3v6.2c0 4.7 3.2 8.3 7.5 10 4.3-1.7 7.5-5.3 7.5-10V5.3Z" />
      <rect x="8.6" y="11" width="6.8" height="5.4" rx="1" {...F} />
      <path {...S} stroke-width={1.5} d="M10.2 11V9.6a1.8 1.8 0 0 1 3.6 0V11" />
    </g>
  ),
  "bolt.fill": () => <path {...F} d="M14 1.5 4.5 13.6h6.6L9.6 22.5l9.9-12.4h-6.6Z" />,
  "qrcode.viewfinder": () => (
    <g>
      <path {...S} stroke-width={1.7} d="M3 8V5.5A2.5 2.5 0 0 1 5.5 3H8M16 3h2.5A2.5 2.5 0 0 1 21 5.5V8M21 16v2.5a2.5 2.5 0 0 1-2.5 2.5H16M8 21H5.5A2.5 2.5 0 0 1 3 18.5V16" />
      <g {...F}>
        <rect x="7" y="7" width="4" height="4" rx=".6" />
        <rect x="13" y="7" width="4" height="4" rx=".6" />
        <rect x="7" y="13" width="4" height="4" rx=".6" />
        <rect x="13" y="13" width="1.8" height="1.8" />
        <rect x="15.2" y="15.2" width="1.8" height="1.8" />
      </g>
    </g>
  ),
  "moon.zzz": () => (
    <g>
      <path {...S} stroke-width={2} d="M10 7a7.5 7.5 0 0 0 8.5 10A8 8 0 1 1 10 7Z" />
      <path {...S} stroke-width={1.5} d="M15 2.5h3l-3 3.2h3M19.5 7.5h2.2l-2.2 2.4h2.2" />
    </g>
  ),
  cpu: () => (
    <g {...S} stroke-width={1.6}>
      <rect x="6" y="6" width="12" height="12" rx="1.5" />
      <rect x="9.5" y="9.5" width="5" height="5" rx=".5" />
      <path d="M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3" />
    </g>
  ),
  memorychip: () => (
    <g {...S} stroke-width={1.6}>
      <rect x="2.5" y="7" width="19" height="9" rx="1.5" />
      <path d="M5.5 16v2.5M9 16v2.5M12.5 16v2.5M16 16v2.5M19 16v2.5M6.5 10.5v2M17.5 10.5v2" />
    </g>
  ),
  internaldrive: () => (
    <g {...S} stroke-width={1.6}>
      <path d="M6.5 5.5h11l3.5 7.5v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4Z" />
      <path d="M3 13h18M16.5 16.2h.1M18.8 16.2h.1" />
    </g>
  ),
  "circle.dashed": () => <circle cx="12" cy="12" r="9" {...S} stroke-width={1.6} stroke-dasharray="2.6 2.6" />,
  circle: () => <circle cx="12" cy="12" r="9.5" {...S} stroke-width={1.8} />,
  tray: () => (
    <g {...S} stroke-width={1.9}>
      <path d="M3 13.5 5.6 5.4A2 2 0 0 1 7.5 4h9a2 2 0 0 1 1.9 1.4L21 13.5V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
      <path d="M3 13.5h5a4 4 0 0 0 8 0h5" />
    </g>
  ),
  gauge: () => (
    <g {...S} stroke-width={1.9}>
      <path d="M4.2 18.5a9.5 9.5 0 1 1 15.6 0Z" />
      <path d="M12 13.5 15.5 8" />
      <circle cx="12" cy="13.5" r="1.2" fill="currentColor" />
    </g>
  ),
  gearshape: () => (
    <g {...S} stroke-width={1.8}>
      <path d="M10.3 2.8h3.4l.5 2.6 1.7.9 2.4-1.1 2.4 2.4-1.1 2.4.9 1.7 2.6.5v3.4l-2.6.5-.9 1.7 1.1 2.4-2.4 2.4-2.4-1.1-1.7.9-.5 2.6h-3.4l-.5-2.6-1.7-.9-2.4 1.1-2.4-2.4 1.1-2.4-.9-1.7-2.6-.5v-3.4l2.6-.5.9-1.7-1.1-2.4 2.4-2.4 2.4 1.1 1.7-.9Z" />
      <circle cx="12" cy="12" r="3.2" />
    </g>
  ),
  "square.and.arrow.up": () => <path {...S} stroke-width={1.9} d="M8.5 9.5H7a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-1.5M12 14.5V2.5M8 6.3l4-3.8 4 3.8" />,
  "plus.app": () => (
    <g {...S} stroke-width={1.9}>
      <rect x="3" y="3" width="18" height="18" rx="4.5" />
      <path d="M12 7.5v9M7.5 12h9" />
    </g>
  ),
  "hand.tap": () => (
    <g {...S} stroke-width={1.8}>
      <path d="M9.5 13V5.5a1.5 1.5 0 0 1 3 0v6l4.6 1a2 2 0 0 1 1.6 2.2l-.6 4.3a2 2 0 0 1-2 1.7H11a2 2 0 0 1-1.6-.8L6 15.5a1.5 1.5 0 0 1 2.2-2Z" />
    </g>
  ),
  "doc.on.clipboard": () => (
    <g {...S} stroke-width={1.8}>
      <path d="M8.5 4.5H7a2 2 0 0 0-2 2V19a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6.5a2 2 0 0 0-2-2h-1.5" />
      <rect x="8.5" y="3" width="7" height="3.2" rx="1" />
      <path d="M8.5 11.5h7M8.5 15h5" />
    </g>
  ),
  bell: () => (
    <g {...S} stroke-width={1.9}>
      <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2H4.5Z" />
      <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
    </g>
  ),
  "wifi.slash": () => <path {...S} stroke-width={1.9} d="M2.5 9a14 14 0 0 1 5-2.8M12 6a14 14 0 0 1 9.5 3M5.5 12.3a9.5 9.5 0 0 1 4-2M15 10.7a9.5 9.5 0 0 1 3.5 1.6M9 15.6a4.8 4.8 0 0 1 6 0M12 19.5h.1M4 4l16 16" />,
  "clock": () => (
    <g {...S} stroke-width={1.9}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3.5 2" />
    </g>
  ),
} satisfies Record<string, () => JSX.Element>;

export type IconName = keyof typeof paths;

export interface IconProps {
  name: IconName;
  /** Lado en px (los SF Symbols escalan con el texto; acá se fija). */
  size?: number | undefined;
  class?: string | undefined;
  /** Etiqueta para VoiceOver; sin etiqueta el ícono es decorativo. */
  label?: string | undefined;
}

export function Icon({ name, size = 20, class: cls, label }: IconProps) {
  return (
    <svg
      class={cls ? `icon ${cls}` : "icon"}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden={label ? undefined : "true"}
      aria-label={label}
      role={label ? "img" : undefined}
      focusable="false"
    >
      {paths[name]()}
    </svg>
  );
}

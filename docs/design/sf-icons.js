// SF Symbols approximations for web mockups. In SwiftUI use Image(systemName:) with the listed names.
(function () {
  if (!document.getElementById('prbar-spin-kf')) {
    const s = document.createElement('style');
    s.id = 'prbar-spin-kf';
    s.textContent = '@keyframes prbarSpin{to{transform:rotate(360deg)}}';
    document.head.appendChild(s);
  }
  const P = (d, extra) => ['path', Object.assign({ d }, extra || {})];
  const C = (cx, cy, r, extra) => ['circle', Object.assign({ cx, cy, r }, extra || {})];
  const R = (x, y, w, h, rx, extra) => ['rect', Object.assign({ x, y, width: w, height: h, rx }, extra || {})];
  const F = { fill: 'currentColor', stroke: 'none' };
  const K = (k) => ({ fill: 'none', style: { stroke: k } });
  const ICONS = {
    'prbar': (k) => [C(6, 5, 2.4), C(6, 19, 2.4), P('M6 7.4v9.2'), C(18, 19, 2.4), P('M18 16.6V9.5a3.5 3.5 0 0 0-3.5-3.5H10.5'), P('M13 3.3L10.3 6l2.7 2.7')],
    'arrow.clockwise': () => [P('M20 12a8 8 0 1 1-2.6-5.9'), P('M20 3.5V8h-4.5')],
    'arrow.triangle.2.circlepath': () => [P('M4.5 11a7.5 7.5 0 0 1 13.4-4.2L19.5 9'), P('M19.5 4.5V9H15'), P('M19.5 13a7.5 7.5 0 0 1-13.4 4.2L4.5 15'), P('M4.5 19.5V15H9')],
    'gearshape': () => [P('M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z'), C(12, 12, 3)],
    'chevron.right': () => [P('M9 5.5l6.5 6.5L9 18.5')],
    'chevron.down': () => [P('M5.5 9l6.5 6.5L18.5 9')],
    'chevron.up.chevron.down': () => [P('M8 9.5l4-4 4 4'), P('M8 14.5l4 4 4-4')],
    'checkmark': () => [P('M5 12.5l4.5 4.5L19 7')],
    'xmark': () => [P('M6.5 6.5l11 11M17.5 6.5l-11 11')],
    'circle.fill': () => [C(12, 12, 5, F)],
    'pause.fill': () => [R(6.5, 5, 4, 14, 1.2, F), R(13.5, 5, 4, 14, 1.2, F)],
    'hourglass': () => [P('M6 3h12M6 21h12'), P('M7.5 3v2.5c0 2 1.2 3.4 2.6 4.6L12 12l1.9-1.9c1.4-1.2 2.6-2.6 2.6-4.6V3'), P('M7.5 21v-2.5c0-2 1.2-3.4 2.6-4.6L12 12l1.9 1.9c1.4 1.2 2.6 2.6 2.6 4.6V21')],
    'magnifyingglass': () => [C(10.5, 10.5, 6.5), P('M15.5 15.5L20.5 20.5')],
    'line.3.horizontal.decrease': () => [P('M4 7h16M7 12h10M10 17h4')],
    'checkmark.circle.fill': (k) => [C(12, 12, 10, F), P('M7.5 12.3l3 3 6-6.3', K(k))],
    'checkmark.circle': () => [C(12, 12, 9.5), P('M7.5 12.3l3 3 6-6.3')],
    'xmark.circle.fill': (k) => [C(12, 12, 10, F), P('M8.5 8.5l7 7M15.5 8.5l-7 7', K(k))],
    'exclamationmark.triangle.fill': (k) => [P('M10.3 3.9a2 2 0 0 1 3.4 0l8 13.6A2 2 0 0 1 20 20.5H4a2 2 0 0 1-1.7-3l8-13.6z', F), P('M12 9v4.5', K(k)), C(12, 17, 0.6, { style: { fill: k, stroke: k } })],
    'exclamationmark.triangle': () => [P('M10.3 3.9a2 2 0 0 1 3.4 0l8 13.6A2 2 0 0 1 20 20.5H4a2 2 0 0 1-1.7-3l8-13.6z'), P('M12 9v4.5'), C(12, 17, 0.6, F)],
    'arrow.up.right': () => [P('M7.5 16.5l9-9M9 7.5h7.5V15')],
    'arrow.right': () => [P('M4.5 12h15M14 6.5l5.5 5.5-5.5 5.5')],
    'arrow.triangle.branch': () => [C(6, 5, 2.2), C(6, 19, 2.2), C(18, 7, 2.2), P('M6 7.2v9.6'), P('M18 9.2c0 5-5.5 5.6-11 8.2')],
    'sparkles': () => [P('M11 3l1.9 5.6L18.5 10.5l-5.6 1.9L11 18l-1.9-5.6L3.5 10.5l5.6-1.9z', F), P('M18.5 14l.9 2.6 2.6.9-2.6.9-.9 2.6-.9-2.6-2.6-.9 2.6-.9z', F)],
    'clock': () => [C(12, 12, 9.5), P('M12 7v5.2l3.2 2')],
    'person.crop.circle': () => [C(12, 12, 9.5), C(12, 10, 3.2), P('M6.6 18.4a7 7 0 0 1 10.8 0')],
    'person.2': () => [C(9, 8, 3.3), P('M2.8 19.5a6.2 6.2 0 0 1 12.4 0'), C(16.8, 8.8, 2.7), P('M16.5 13.6a5.3 5.3 0 0 1 5.2 5.4')],
    'books.vertical': () => [R(3, 4, 4.5, 16, 1), R(9.5, 4, 4.5, 16, 1), P('M15.6 6l3.6-1 3.4 13.6-3.6 1z')],
    'bell': () => [P('M6 16.5V11a6 6 0 0 1 12 0v5.5l1.6 2H4.4z'), P('M10 20.5a2 2 0 0 0 4 0')],
    'bell.badge': () => [P('M6 16.5V11a6 6 0 0 1 12 0v5.5l1.6 2H4.4z'), P('M10 20.5a2 2 0 0 0 4 0')],
    'doc.on.doc': () => [R(8.5, 8.5, 11.5, 12, 2), P('M15.5 8.5V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8.5a2 2 0 0 0 2 2h2.5')],
    'plus': () => [P('M12 5v14M5 12h14')],
    'minus': () => [P('M5 12h14')],
    'wifi': () => [P('M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.6 16a5 5 0 0 1 6.8 0'), C(12, 19.2, 1.2, F)],
    'wifi.slash': () => [P('M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.6 16a5 5 0 0 1 6.8 0'), C(12, 19.2, 1.2, F), P('M3.5 3.5l17 17')],
    'text.bubble': () => [P('M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v9a1.5 1.5 0 0 1-1.5 1.5H10l-4.5 4v-4h0A1.5 1.5 0 0 1 4 14.5z'), P('M8 8.5h8M8 11.5h5')],
    'terminal': () => [R(3, 4, 18, 16, 2.5), P('M7 9.5l2.8 2.5L7 14.5M12 15h5')],
    'folder': () => [P('M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.2h8.5A1.5 1.5 0 0 1 21 8.7v9.3a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18z')],
    'battery.100': () => [R(2, 7, 18, 10, 3), R(4, 9, 14, 6, 1.5, F), P('M22 10.5v3')],
    'switch.2': () => [P('M4 8h8.5M17.5 8H20M4 16h2.5M11.5 16H20'), C(15, 8, 2.5), C(9, 16, 2.5)],
    'eye': () => [P('M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z'), C(12, 12, 3)],
    'ellipsis.circle': () => [C(12, 12, 9.5), C(8, 12, 0.9, F), C(12, 12, 0.9, F), C(16, 12, 0.9, F)],
    'square.and.arrow.up': () => [P('M8 8.5H6.5A1.5 1.5 0 0 0 5 10v9a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 19v-9a1.5 1.5 0 0 0-1.5-1.5H16'), P('M12 3v11M8.5 6.5L12 3l3.5 3.5')],
    'arrow.up.forward.app': () => [R(3.5, 3.5, 17, 17, 4), P('M9.5 14.5l5-5M10.5 9.5h4v4')],
    'line.3.horizontal.decrease.circle': () => [C(12, 12, 9.5), P('M7.5 9h9M9.5 12.5h5M11 16h2')],
    'checkmark.seal': () => [P('M12 2.8l2.3 1.7 2.8-.2.9 2.7 2.4 1.5-.8 2.7.8 2.7-2.4 1.5-.9 2.7-2.8-.2L12 19.6l-2.3-1.7-2.8.2-.9-2.7-2.4-1.5.8-2.7-.8-2.7 2.4-1.5.9-2.7 2.8.2z'), P('M8.5 11.3l2.4 2.4 4.6-4.8')],
  };

  function SFIcon(props) {
    const h = window.React.createElement;
    const size = Number(props.size || 14);
    const fn = ICONS[props.name] || ICONS['circle.fill'];
    const knock = props.knock || '#fff';
    const els = fn(knock).map((e, i) => h(e[0], Object.assign({ key: i }, e[1])));
    return h('svg', {
      width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
      stroke: props.color || 'currentColor', strokeWidth: Number(props.weight || 1.8),
      strokeLinecap: 'round', strokeLinejoin: 'round',
      style: { display: 'block', flex: 'none', color: props.color || 'currentColor' }
    }, els);
  }

  function SFSpinner(props) {
    const h = window.React.createElement;
    const size = Number(props.size || 11);
    return h('svg', {
      width: size, height: size, viewBox: '0 0 24 24',
      style: { display: 'block', flex: 'none', animation: 'prbarSpin 0.9s linear infinite' }
    },
      h('circle', { cx: 12, cy: 12, r: 9, fill: 'none', stroke: 'currentColor', strokeOpacity: 0.25, strokeWidth: 3 }),
      h('path', { d: 'M12 3a9 9 0 0 1 9 9', fill: 'none', stroke: 'currentColor', strokeWidth: 3, strokeLinecap: 'round' })
    );
  }

  window.SFIcon = SFIcon;
  window.SFSpinner = SFSpinner;
  window.SF_ICON_NAMES = Object.keys(ICONS);
  if (typeof module !== 'undefined') module.exports = { SFIcon, SFSpinner };
})();

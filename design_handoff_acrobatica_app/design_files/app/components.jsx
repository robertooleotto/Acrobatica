// Acrobatica UI Kit — shared atoms & icon set
// Visual source of truth: ios/Acrobatica/DesignSystem/* (Theme, BrandButton, GlassPill, etc.)
// Icons: Lucide-geometry stroke icons standing in for the app's SF Symbols (flagged in README).

const T = {
  yellow: '#F5DC0F', navy: '#0F1E48', ink: '#1A1A1A',
  paper: '#F7F6F2', grayBg: '#EEECE6', white: '#FFFFFF',
  hair: 'rgba(15,30,72,0.08)', hair2: 'rgba(15,30,72,0.16)', muted: 'rgba(15,30,72,0.55)',
  success: '#1FA463', warning: '#F5A524', danger: '#D9342B',
  font: '-apple-system, system-ui, "SF Pro Text", sans-serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
};

// ── Icon set (24px viewBox, currentColor) ───────────────────────────────
const ACRO_ICONS = {
  camera:    'M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z|c:12,13,4',
  plus:      'M12 5v14M5 12h14',
  chevron:   'M9 6l6 6-6 6',
  pin:       'M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z|c:12,10,3',
  ruler:     'M3 8l5-5 13 13-5 5zM8 3l3 3M11 6l-2 2M13 8l3 3M16 11l-2 2',
  viewfinder:'M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2|c:12,12,3',
  doc:       'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h6',
  share:     'M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8M16 6l-4-4-4 4M12 2v13',
  x:         'M18 6L6 18M6 6l12 12',
  undo:      'M9 14L4 9l5-5M4 9h11a5 5 0 0 1 5 5v0a5 5 0 0 1-5 5H9',
  stopFill:  'F:M7 6h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1z',
  check:     'M22 11.08V12a10 10 0 1 1-5.93-9.14M22 4L12 14.01l-3-3',
  arrowsLR:  'M3 12h18M7 8l-4 4 4 4M17 8l4 4-4 4',
  warnTri:   'M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0zM12 9v4M12 17h.01',
  signature: 'M3 17c3-1 4-8 6-8s2 5 4 5 2-4 4-4 2 3 4 3M3 21h18',
  stack:     'M4 7l8-4 8 4-8 4-8-4zM4 12l8 4 8-4M4 17l8 4 8-4',
  building:  'F:M3 21V7l8-4v4l8-4v18h-7v-5h-2v5z',
  window:    'M4 4h16v16H4zM12 4v16M4 12h16',
  door:      'M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17M14 12h.01M3 21h18',
  bolt:      'M13 2L3 14h7l-1 8 10-12h-7z',
  cloud:     'M16 16l-4-4-4 4M12 12v9M20 16.7A5 5 0 0 0 18 7h-1.26A8 8 0 1 0 4 15.25',
  csv:       'M9 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zM14 2v6h6M8 13h8M8 17h8',
  back:      'M19 12H5M12 19l-7-7 7-7',
  search:    'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.35-4.35',
};

function Icon({ name, size = 22, color = 'currentColor', stroke = 2, style = {} }) {
  const raw = ACRO_ICONS[name] || '';
  const parts = raw.split('|');
  const filled = parts[0].startsWith('F:');
  const d = filled ? parts[0].slice(2) : parts[0];
  const circle = parts.find(p => p.startsWith('c:'));
  let cx, cy, r;
  if (circle) { const [a, b, c] = circle.slice(2).split(','); cx = a; cy = b; r = c; }
  return (
    <svg width={size} height={size} viewBox="0 0 24 24"
      fill={filled ? color : 'none'} stroke={filled ? 'none' : color}
      strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" style={style}>
      <path d={d} />
      {circle && <circle cx={cx} cy={cy} r={r} />}
    </svg>
  );
}

// ── Brand button (primary / secondary / ghost) ──────────────────────────
function BrandButton({ title, icon, kind = 'primary', disabled, onClick, style = {} }) {
  const bg = { primary: T.yellow, secondary: T.paper, ghost: 'transparent' }[kind];
  const border = kind === 'primary' ? 'none' : `1px solid ${T.hair2}`;
  return (
    <button onClick={disabled ? undefined : onClick} style={{
      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
      width: '100%', minHeight: 52, borderRadius: 22, border,
      background: bg, color: T.navy, font: `600 17px ${T.font}`,
      opacity: disabled ? 0.4 : 1, cursor: disabled ? 'default' : 'pointer',
      transition: 'transform .12s ease, filter .12s ease', ...style,
    }}
      onMouseDown={e => !disabled && (e.currentTarget.style.transform = 'scale(0.98)')}
      onMouseUp={e => (e.currentTarget.style.transform = 'scale(1)')}
      onMouseLeave={e => (e.currentTarget.style.transform = 'scale(1)')}>
      {icon && <Icon name={icon} size={19} stroke={2.4} />}
      {title}
    </button>
  );
}

// ── Card (white, hairline border, r16) ──────────────────────────────────
function Card({ children, pad = 14, radius = 16, style = {}, onClick }) {
  return (
    <div onClick={onClick} style={{
      background: T.white, border: `1px solid ${T.hair}`, borderRadius: radius,
      padding: pad, cursor: onClick ? 'pointer' : 'default', ...style,
    }}>{children}</div>
  );
}

// ── Status chip ──────────────────────────────────────────────────────────
function StatoChip({ text, tint }) {
  return (
    <span style={{
      font: `600 10px ${T.font}`, color: tint, padding: '3px 8px',
      borderRadius: 999, background: tint.replace(/[\d.]+\)$/, '') ? hexWash(tint) : tint,
    }}>{text}</span>
  );
}
function hexWash(hex) {
  if (hex === T.success) return T.success + '1F';
  if (hex === T.warning) return T.warning + '1F';
  if (hex === T.muted) return 'rgba(15,30,72,0.10)';
  return hex + '1F';
}

// ── Metric card ────────────────────────────────────────────────────────
function MetricCard({ label, value, highlight }) {
  return (
    <div style={{
      flex: 1, padding: 12, borderRadius: 12,
      background: highlight ? 'rgba(245,220,15,0.18)' : T.white,
      border: `1px solid ${highlight ? T.yellow : T.hair}`,
    }}>
      <div style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>{label}</div>
      <div style={{ font: `700 22px ${T.font}`, color: T.navy, marginTop: 4 }}>{value}</div>
    </div>
  );
}

// ── Tile icon (navy rounded square w/ yellow glyph) ──────────────────────
function Tile({ icon, size = 56, bg = T.navy, color = T.yellow, glyph = 22, stroke = 2 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: 14, background: bg, flex: 'none',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}><Icon name={icon} size={glyph} color={color} stroke={stroke} /></div>
  );
}

// ── Glass pill (for dark AR chrome) ──────────────────────────────────────
function GlassPill({ children, style = {} }) {
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 8, padding: '8px 14px',
      borderRadius: 999, background: 'rgba(255,255,255,0.13)',
      border: '0.5px solid rgba(255,255,255,0.18)', backdropFilter: 'blur(10px)',
      WebkitBackdropFilter: 'blur(10px)', color: '#fff', font: `600 14px ${T.font}`, ...style,
    }}>{children}</div>
  );
}
function GlassCircle({ icon, onClick, size = 44 }) {
  return (
    <button onClick={onClick} style={{
      width: size, height: size, borderRadius: '50%', border: '0.5px solid rgba(255,255,255,0.18)',
      background: 'rgba(255,255,255,0.14)', backdropFilter: 'blur(10px)', WebkitBackdropFilter: 'blur(10px)',
      color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
    }}><Icon name={icon} size={18} stroke={2.4} /></button>
  );
}

Object.assign(window, {
  T, Icon, BrandButton, Card, StatoChip, MetricCard, Tile, GlassPill, GlassCircle, hexWash,
});

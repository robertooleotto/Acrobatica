// Acrobatica Prototype — shared helpers, extra icons, chrome (tab bar, sheets, tablet frame)
const useState = (...a) => React.useState(...a);
const useEffect = (...a) => React.useEffect(...a);
const useRef = (...a) => React.useRef(...a);

// ── Extra icons (Lucide geometry, same conventions as ACRO_ICONS) ────────
Object.assign(ACRO_ICONS, {
  home:     'M3 9.5L12 3l9 6.5V20a2 2 0 0 1-2 2h-4v-7h-6v7H5a2 2 0 0 1-2-2z',
  users:    'M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75|c:9,7,4',
  user:     'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2|c:12,7,4',
  gear:     'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z',
  phone:    'M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z',
  mail:     'M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM22 6l-10 7L2 6',
  euro:     'M4 10h12M4 14h9M19 6c-1.5-1.24-3.4-2-5.5-2-4.7 0-8.5 3.58-8.5 8s3.8 8 8.5 8c2.1 0 4-.76 5.5-2',
  logout:   'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9',
  pencil:   'M17 3a2.83 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5z',
  trash:    'M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6',
  box:      'M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16zM3.27 6.96L12 12.01l8.73-5.05M12 22.08V12',
  brush:    'M9.06 11.9l8.07-8.06a2.85 2.85 0 1 1 4.03 4.03l-8.06 8.08M7.07 14.94c-1.66 0-3 1.35-3 3.02 0 1.33-2.5 1.52-2 2.02 1.08 1.1 2.49 2.02 4 2.02 2.2 0 4-1.8 4-4.04a3.01 3.01 0 0 0-3-3.02z',
  lasso:    'M7 22a5 5 0 0 1-2-4M3.3 14A6.8 6.8 0 0 1 2 10c0-4.4 4.5-8 10-8s10 3.6 10 8-4.5 8-10 8c-1.4 0-2.7-.2-3.9-.6|c:5,18,2.5',
  grid:     'M3 3h18v18H3zM3 9h18M3 15h18M9 3v18M15 3v18',
  rotate:   'M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15',
  tag:      'M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.83zM7 7h.01',
  eye:      'M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z|c:12,12,3',
  lock:     'M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2zM7 11V7a5 5 0 0 1 10 0v4',
  info:     'M12 16v-4M12 8h.01|c:12,12,10',
  chevDown: 'M6 9l6 6 6-6',
  minus:    'M5 12h14',
});

// ── Wordmark (de-facto: yellow tile + word — no official logo in repo) ───
function Wordmark({ size = 40, word = 22, color = T.navy, onNavy = false }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: size * 0.3 }}>
      <div style={{
        width: size, height: size, borderRadius: size * 0.28, background: T.yellow,
        display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none',
      }}><Icon name="building" size={size * 0.55} color={T.navy} /></div>
      <span style={{ font: `700 ${word}px ${T.font}`, color: onNavy ? '#fff' : color, letterSpacing: '-.01em' }}>Acrobatica</span>
    </div>
  );
}

// ── Nav bar (inline title + back) ────────────────────────────────────────
function NavBar({ title, onBack, trailing }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '58px 12px 8px', position: 'relative' }}>
      {onBack && <button onClick={onBack} style={{ border: 'none', background: 'none', cursor: 'pointer', color: T.navy, padding: 6, display: 'inline-flex' }}>
        <Icon name="back" size={22} stroke={2.2} />
      </button>}
      <span style={{ position: 'absolute', left: 60, right: 60, textAlign: 'center', font: `600 17px ${T.font}`, color: T.navy, pointerEvents: 'none', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
      <span style={{ marginLeft: 'auto' }}>{trailing}</span>
    </div>
  );
}

function statoTint(s) {
  return s === 'Elaborato' || s === 'Completato' || s === 'Accettato' ? T.success
    : s === 'In cattura' || s === 'Inviato' || s === 'In elaborazione' ? T.warning
    : s === 'Rifiutato' || s === 'Errore' ? T.danger : T.muted;
}

// ── Section header ───────────────────────────────────────────────────────
function SectionHeader({ title, count, action, onAction }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={{ font: `600 17px ${T.font}`, color: T.navy }}>{title}</span>
      {count !== undefined && <span style={{ font: `500 12px ${T.font}`, color: T.muted }}>{count}</span>}
      {action && <button onClick={onAction} style={{ marginLeft: 'auto', border: 'none', background: 'none', cursor: 'pointer', color: T.navy, font: `600 13px ${T.font}`, padding: 4, display: 'inline-flex', alignItems: 'center', gap: 4 }}>{action}</button>}
    </div>
  );
}

// ── Empty state ──────────────────────────────────────────────────────────
function EmptyState({ icon, title, subtitle, cta, onCta, pad = 48 }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, padding: `${pad}px 32px`, textAlign: 'center' }}>
      <div style={{ width: 72, height: 72, borderRadius: 22, background: T.grayBg, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon name={icon} size={34} color={T.muted} stroke={1.7} />
      </div>
      <div style={{ font: `600 17px ${T.font}`, color: T.navy, marginTop: 6 }}>{title}</div>
      <div style={{ font: `400 14px ${T.font}`, color: T.muted, maxWidth: 240 }}>{subtitle}</div>
      {cta && <div style={{ width: '100%', maxWidth: 260, marginTop: 10 }}><BrandButton title={cta} icon="plus" onClick={onCta} /></div>}
    </div>
  );
}

// ── Input field ──────────────────────────────────────────────────────────
function Field({ label, value, placeholder, icon, error, suffix, secure, onChange }) {
  const [show, setShow] = useState(false);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      {label && <span style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: error ? T.danger : T.muted }}>{label}</span>}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8, background: T.grayBg, borderRadius: 12,
        border: `1px solid ${error ? T.danger : 'transparent'}`, padding: '0 12px', height: 48,
      }}>
        {icon && <Icon name={icon} size={17} color={T.muted} stroke={2} />}
        <input value={value} placeholder={placeholder} type={secure && !show ? 'password' : 'text'}
          onChange={e => onChange && onChange(e.target.value)}
          style={{ flex: 1, border: 'none', outline: 'none', background: 'none', font: `400 15px ${T.font}`, color: T.navy, minWidth: 0 }} />
        {suffix && <span style={{ font: `600 13px ${T.mono}`, color: T.muted }}>{suffix}</span>}
        {secure && <button onClick={() => setShow(s => !s)} style={{ border: 'none', background: 'none', cursor: 'pointer', color: show ? T.navy : T.muted, display: 'inline-flex', padding: 2 }}><Icon name="eye" size={17} stroke={2} /></button>}
      </div>
      {error && <span style={{ font: `500 12px ${T.font}`, color: T.danger }}>{error}</span>}
    </div>
  );
}

// ── Segmented control ────────────────────────────────────────────────────
function Segmented({ options, value, onChange, small }) {
  return (
    <div style={{ display: 'flex', background: T.grayBg, borderRadius: 999, padding: 3 }}>
      {options.map(o => (
        <button key={o} onClick={() => onChange && onChange(o)} style={{
          flex: 1, border: 'none', cursor: 'pointer', borderRadius: 999,
          padding: small ? '6px 10px' : '8px 12px',
          background: value === o ? T.white : 'transparent',
          boxShadow: value === o ? `inset 0 0 0 1px ${T.hair2}` : 'none',
          color: value === o ? T.navy : T.muted, font: `600 ${small ? 12 : 13}px ${T.font}`,
          whiteSpace: 'nowrap',
        }}>{o}</button>
      ))}
    </div>
  );
}

// ── Bottom sheet (1.2 Nuovo cantiere, nuovo cliente, nuova voce) ─────────
function Sheet({ title, children, onClose, cta, onCta }) {
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 40 }}>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(15,30,72,0.35)' }} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0, background: T.paper,
        borderRadius: '28px 28px 0 0', padding: '10px 16px 40px',
        display: 'flex', flexDirection: 'column', gap: 14, animation: 'acro-rise .3s ease',
      }}>
        <div style={{ width: 36, height: 5, borderRadius: 999, background: T.hair2, margin: '0 auto' }} />
        <div style={{ display: 'flex', alignItems: 'center' }}>
          <span style={{ font: `600 20px ${T.font}`, color: T.navy }}>{title}</span>
          <button onClick={onClose} style={{ marginLeft: 'auto', border: 'none', background: T.grayBg, borderRadius: 999, width: 30, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', color: T.muted }}>
            <Icon name="x" size={15} stroke={2.4} />
          </button>
        </div>
        {children}
        <BrandButton title={cta} onClick={onCta} style={{ marginTop: 4 }} />
      </div>
    </div>
  );
}

// ── Tab bar ──────────────────────────────────────────────────────────────
const TABS = [
  { id: '0.3', icon: 'home', label: 'Home' },
  { id: '1.1', icon: 'building', label: 'Cantieri' },
  { id: '5.1', icon: 'doc', label: 'Preventivi' },
  { id: '6.1', icon: 'users', label: 'Clienti' },
  { id: '6.4', icon: 'user', label: 'Profilo' },
];
function TabBar({ active, go }) {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 30,
      background: 'rgba(255,255,255,0.92)', backdropFilter: 'blur(14px)', WebkitBackdropFilter: 'blur(14px)',
      borderTop: `1px solid ${T.hair}`, display: 'flex', padding: '8px 8px 30px',
    }}>
      {TABS.map(t => {
        const on = t.id === active;
        return (
          <button key={t.id} onClick={() => go({ id: t.id })} style={{
            flex: 1, border: 'none', background: 'none', cursor: 'pointer',
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '4px 0',
            color: on ? T.navy : T.muted,
          }}>
            <Icon name={t.icon} size={22} stroke={on ? 2.4 : 1.9} />
            <span style={{ font: `${on ? 600 : 500} 10px ${T.font}` }}>{t.label}</span>
          </button>
        );
      })}
    </div>
  );
}

// Scrollable screen body that leaves room for the tab bar
function ScreenScroll({ children, tabbed }) {
  return (
    <div style={{ position: 'absolute', inset: 0, overflowY: 'auto', overflowX: 'hidden', background: T.paper, paddingBottom: tabbed ? 90 : 0, boxSizing: 'border-box' }}>
      {children}
    </div>
  );
}

// ── iPad landscape frame ─────────────────────────────────────────────────
function TabletFrame({ children, dark }) {
  return (
    <div style={{
      width: 1194, height: 834, borderRadius: 40, overflow: 'hidden', position: 'relative',
      background: dark ? '#000' : T.paper,
      boxShadow: '0 40px 80px rgba(0,0,0,0.18), 0 0 0 1.5px rgba(0,0,0,0.14), inset 0 0 0 14px #0b0b0d',
      fontFamily: T.font, WebkitFontSmoothing: 'antialiased',
    }}>
      <div style={{ position: 'absolute', top: 14, left: 14, right: 14, bottom: 14, borderRadius: 28, overflow: 'hidden' }}>
        {/* status bar */}
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, zIndex: 60, display: 'flex', alignItems: 'center', padding: '10px 24px 0', color: dark ? '#fff' : T.navy, font: `590 15px ${T.font}` }}>
          <span>9:41 · Ven 4 lug</span>
          <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            <svg width="19" height="12" viewBox="0 0 19 12"><rect x="0" y="7.5" width="3.2" height="4.5" rx="0.7" fill="currentColor"/><rect x="4.8" y="5" width="3.2" height="7" rx="0.7" fill="currentColor"/><rect x="9.6" y="2.5" width="3.2" height="9.5" rx="0.7" fill="currentColor"/><rect x="14.4" y="0" width="3.2" height="12" rx="0.7" fill="currentColor"/></svg>
            <span style={{ font: `500 13px ${T.font}` }}>100%</span>
            <svg width="27" height="13" viewBox="0 0 27 13"><rect x="0.5" y="0.5" width="23" height="12" rx="3.5" stroke="currentColor" strokeOpacity="0.35" fill="none"/><rect x="2" y="2" width="20" height="9" rx="2" fill="currentColor"/><path d="M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z" fill="currentColor" fillOpacity="0.4"/></svg>
          </span>
        </div>
        {children}
        {/* home indicator */}
        <div style={{ position: 'absolute', bottom: 6, left: '50%', transform: 'translateX(-50%)', width: 220, height: 5, borderRadius: 999, background: dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.25)', zIndex: 60, pointerEvents: 'none' }} />
      </div>
    </div>
  );
}

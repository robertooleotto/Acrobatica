// Acrobatica Prototype — Fasi 1–3 (Cantieri, Cattura, Elaborazione 3D)
// Core screens forked from ui_kits/ios-app/screens.jsx (faithful), wired + states added.

// Shared faux-facade backdrop (stylised stand-in for the AR camera feed / 3D render).
function FacadeBackdrop({ rows = 5, cols = 6, tone = '#8a8275' }) {
  const wins = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    wins.push(<div key={`${r}-${c}`} style={{
      background: 'rgba(20,28,46,0.55)', borderRadius: 3,
      boxShadow: 'inset 0 0 0 1.5px rgba(255,255,255,0.10)',
    }} />);
  }
  return (
    <div style={{ position: 'absolute', inset: 0, overflow: 'hidden',
      background: `linear-gradient(160deg, ${tone}, #5f5848 70%, #4a4438)` }}>
      <div style={{ position: 'absolute', inset: 0,
        background: 'repeating-linear-gradient(90deg, transparent 0 78px, rgba(0,0,0,0.08) 78px 80px)' }} />
      <div style={{ position: 'absolute', left: '8%', right: '8%', top: '20%', bottom: '14%',
        display: 'grid', gridTemplateColumns: `repeat(${cols},1fr)`, gridTemplateRows: `repeat(${rows},1fr)`,
        gap: 16 }}>{wins}</div>
      <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(180deg, rgba(0,0,0,0.25), transparent 30%, transparent 70%, rgba(0,0,0,0.45))' }} />
    </div>
  );
}

// Flat ortho stand-in (rectified facade) with optional children overlays
function OrthoPlaceholder({ height = 150, radius = 12, rows = 4, cols = 7, children, skew }) {
  return (
    <div style={{ position: 'relative', height, borderRadius: radius, overflow: 'hidden', transform: skew, transformStyle: 'preserve-3d' }}>
      <FacadeBackdrop rows={rows} cols={cols} tone="#948a7a" />
      {children}
    </div>
  );
}

// ── 1.1 Cantieri (lista) ─────────────────────────────────────────────────
function CantieriList({ cantieri, go, onNew }) {
  return (
    <ScreenScroll tabbed>
      <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', padding: '58px 16px 8px' }}>
        <h1 style={{ margin: 0, font: `700 34px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Cantieri</h1>
        <button onClick={onNew} style={{ border: 'none', background: 'none', cursor: 'pointer', padding: 6, color: T.navy }}>
          <Icon name="plus" size={24} stroke={2.4} />
        </button>
      </div>
      {cantieri.length === 0 ? (
        <EmptyState icon="building" title="Nessun cantiere" subtitle="Tocca + in alto per crearne uno" cta="Nuovo cantiere" onCta={onNew} />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '12px 16px 40px' }}>
          {cantieri.map(c => (
            <Card key={c.id} onClick={() => go({ id: '1.4', cantiere: c.id })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <Tile icon="building" />
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
                <span style={{ font: `600 17px ${T.font}`, color: T.navy }}>{c.nome}</span>
                <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>{c.cliente}</span>
                <span style={{ font: `500 11px ${T.font}`, color: T.muted }}>{c.rilievi.length} facciat{c.rilievi.length === 1 ? 'a' : 'e'}</span>
              </div>
              <div style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={18} stroke={2.2} /></div>
            </Card>
          ))}
        </div>
      )}
    </ScreenScroll>
  );
}

// ── 1.2 Nuovo cantiere (sheet) ───────────────────────────────────────────
function NuovoCantiereSheet({ onClose, onCrea }) {
  const [nome, setNome] = useState('');
  const [ind, setInd] = useState('');
  const [cli, setCli] = useState('');
  return (
    <Sheet title="Nuovo cantiere" onClose={onClose} cta="Crea cantiere" onCta={onCrea}>
      <Field label="Nome" placeholder="Es. Condominio Garibaldi" value={nome} onChange={setNome} />
      <Field label="Indirizzo" icon="pin" placeholder="Via, numero, città" value={ind} onChange={setInd} />
      <Field label="Cliente" icon="users" placeholder="Cerca o crea cliente" value={cli} onChange={setCli} />
    </Sheet>
  );
}

// ── 1.4 Dettaglio cantiere ───────────────────────────────────────────────
function DettaglioCantiere({ cantiere, go }) {
  const onNuovoRilievo = () => go({ id: '2.1', cantiere: cantiere.id });
  return (
    <ScreenScroll>
      <NavBar title={cantiere.nome} onBack={() => go({ id: '1.1' })} trailing={
        <button onClick={onNuovoRilievo} style={{ border: 'none', background: 'none', cursor: 'pointer', color: T.navy, padding: 4 }}>
          <Icon name="camera" size={21} stroke={2.2} />
        </button>} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 20, padding: '8px 16px 40px' }}>
        <Card pad={16} radius={18} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Tile icon="building" />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>{cantiere.cliente}</span>
              <span style={{ font: `600 20px ${T.font}`, color: T.navy }}>{cantiere.nome}</span>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: T.muted, font: `400 14px ${T.font}` }}>
            <Icon name="pin" size={16} stroke={2} />{cantiere.indirizzo}
          </div>
        </Card>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <SectionHeader title="Facciate" count={cantiere.rilievi.length} />
          {cantiere.rilievi.length === 0 && (
            <EmptyState pad={20} icon="stack" title="Nessun rilievo" subtitle="Avvia la cattura per rilevare la prima facciata" />
          )}
          {cantiere.rilievi.map(r => (
            <Card key={r.id} radius={14} pad={12} onClick={() => go({ id: '3.1', cantiere: cantiere.id, rilievo: r.id })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <Tile icon="stack" size={56} bg={T.grayBg} color={'rgba(15,30,72,0.5)'} glyph={24} />
              <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>{r.nome}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <StatoChip text={r.stato} tint={statoTint(r.stato)} />
                  <span style={{ font: `500 11px ${T.font}`, color: T.muted }}>{r.foto} foto</span>
                  {r.areaNetta > 0 && <span style={{ font: `500 11px ${T.font}`, color: T.muted }}>{r.areaNetta.toFixed(1)} m²</span>}
                </div>
              </div>
              <div style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={18} stroke={2.2} /></div>
            </Card>
          ))}
          <BrandButton title="Nuovo rilievo" icon="plus" kind="secondary" onClick={onNuovoRilievo} />
        </div>
      </div>
    </ScreenScroll>
  );
}

// ── 2.1 / 2.2 Cattura AR (live + frame strip) ────────────────────────────
function CatturaAR({ onClose, onStop, initialShots = 0, pad = false }) {
  const [shots, setShots] = useState(Array.from({ length: initialShots }, () => 1));
  const [t, setT] = useState(initialShots * 9);
  useEffect(() => { const id = setInterval(() => setT(x => x + 1), 1000); return () => clearInterval(id); }, []);
  const elapsed = `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`;
  const baseline = shots.length === 0 ? null
    : shots.length === 1 ? { color: T.warning, icon: 'arrowsLR', text: 'Quasi: 0.48 m' }
    : { color: T.success, icon: 'check', text: 'Baseline OK: 0.72 m' };
  const hint = shots.length === 0 ? 'Inquadra la facciata e scatta'
    : shots.length === 1 ? "Spostati ~1m a lato, mantieni l'overlap, poi scatta"
    : shots.length < 5 ? 'Continua a panare lateralmente' : null;
  const topY = pad ? 34 : 54;

  return (
    <div style={{ position: 'absolute', inset: 0, background: '#000', overflow: 'hidden' }}>
      <FacadeBackdrop cols={pad ? 10 : 6} />
      <Reticle />
      {/* top bar */}
      <div style={{ position: 'absolute', top: topY, left: 16, right: 16, display: 'flex', alignItems: 'center', justifyContent: 'space-between', zIndex: 10 }}>
        <GlassCircle icon="x" onClick={onClose} />
        <GlassPill>
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: T.yellow, boxShadow: '0 0 6px rgba(245,220,15,.5)' }} />
          <span style={{ font: `600 13px ${T.mono}`, fontVariantNumeric: 'tabular-nums' }}>REC · {elapsed}</span>
        </GlassPill>
        <GlassCircle icon="bolt" />
      </div>
      {/* frame counter */}
      <div style={{ position: 'absolute', top: topY + 56, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 10 }}>
        <GlassPill style={{ padding: '5px 12px' }}>
          <span style={{ font: `600 12px ${T.mono}` }}>{shots.length} frame</span>
        </GlassPill>
      </div>
      {/* hints */}
      <div style={{ position: 'absolute', top: '46%', left: 0, right: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, zIndex: 10 }}>
        {baseline && <GlassPill><Icon name={baseline.icon} size={16} color={baseline.color} stroke={2.4} />{baseline.text}</GlassPill>}
        {hint && <GlassPill><Icon name="viewfinder" size={16} color={T.yellow} stroke={2.2} />{hint}</GlassPill>}
      </div>
      {/* film strip (2.2) */}
      {shots.length > 0 && (
        <div style={{ position: 'absolute', bottom: 150, left: 16, right: 16, display: 'flex', gap: 8, zIndex: 10 }}>
          {shots.slice(-(pad ? 12 : 6)).reverse().map((s, i) => (
            <div key={i} style={{ width: 56, height: 56, borderRadius: 10, overflow: 'hidden', position: 'relative', border: i === 0 ? `2px solid ${T.yellow}` : '1px solid rgba(255,255,255,0.6)', flex: 'none' }}>
              <FacadeBackdrop rows={3} cols={3} tone="#94897a" />
              {i === 0 && <span style={{ position: 'absolute', right: 3, bottom: 3, width: 14, height: 14, borderRadius: '50%', background: T.yellow, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={9} color={T.navy} stroke={3} /></span>}
            </div>
          ))}
        </div>
      )}
      {/* bottom bar */}
      <div style={{ position: 'absolute', bottom: 44, left: 24, right: 24, display: 'flex', alignItems: 'center', justifyContent: 'space-between', zIndex: 10 }}>
        <GlassCircle icon="undo" onClick={() => setShots(s => s.slice(0, -1))} />
        <button onClick={() => setShots(s => [...s, 1])} style={{ width: 76, height: 76, borderRadius: '50%', border: '4px solid #fff', background: 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', padding: 0 }}>
          <span style={{ width: 62, height: 62, borderRadius: '50%', background: T.yellow, boxShadow: '0 0 10px rgba(245,220,15,.4)' }} />
        </button>
        <button onClick={() => onStop(shots.length)} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '12px 18px', borderRadius: 999, background: T.navy, color: T.yellow, border: 'none', font: `600 15px ${T.font}`, cursor: 'pointer' }}>
          <Icon name="stopFill" size={15} color={T.yellow} stroke={0} />Stop
        </button>
      </div>
    </div>
  );
}

function Reticle() {
  const col = 'rgba(245,220,15,0.85)';
  const corner = (pos) => (<span style={{ position: 'absolute', width: 24, height: 24, border: `3px solid ${col}`, ...pos }} />);
  return (
    <div style={{ position: 'absolute', top: '50%', left: '50%', width: 150, height: 150, transform: 'translate(-50%,-50%)', zIndex: 5 }}>
      {corner({ top: 0, left: 0, borderRight: 'none', borderBottom: 'none' })}
      {corner({ top: 0, right: 0, borderLeft: 'none', borderBottom: 'none' })}
      {corner({ bottom: 0, left: 0, borderRight: 'none', borderTop: 'none' })}
      {corner({ bottom: 0, right: 0, borderLeft: 'none', borderTop: 'none' })}
      <span style={{ position: 'absolute', top: '50%', left: '50%', width: 28, height: 1.5, background: col, transform: 'translate(-50%,-50%)' }} />
      <span style={{ position: 'absolute', top: '50%', left: '50%', width: 1.5, height: 28, background: col, transform: 'translate(-50%,-50%)' }} />
    </div>
  );
}

// ── 3.1 Risultato panorama ───────────────────────────────────────────────
function RisultatoPanorama({ rilievo, processing, go, backTo }) {
  const [phase, setPhase] = useState(processing ? 0 : 2); // 0 elaborazione, 1 quasi, 2 pronto
  useEffect(() => {
    if (!processing) return;
    const a = setTimeout(() => setPhase(1), 1400);
    const b = setTimeout(() => setPhase(2), 2800);
    return () => { clearTimeout(a); clearTimeout(b); };
  }, [processing]);
  const ready = phase === 2;
  return (
    <ScreenScroll>
      <NavBar title={rilievo.nome} onBack={() => go(backTo)} trailing={
        <span style={{ color: T.navy, padding: 4, display: 'inline-flex' }}><Icon name="share" size={20} stroke={2.1} /></span>} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '8px 16px 40px' }}>
        {!ready && (
          <Card style={{ display: 'flex', alignItems: 'center', gap: 12, borderColor: T.warning, background: 'rgba(245,165,36,0.10)' }}>
            <span style={{ width: 22, height: 22, borderRadius: '50%', border: `3px solid rgba(245,165,36,0.25)`, borderTopColor: T.warning, animation: 'acro-spin .9s linear infinite', flex: 'none' }} />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>{phase === 0 ? 'Elaborazione in corso' : 'Calcolo metrature…'}</span>
              <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>{phase === 0 ? 'Ricostruzione 3D della facciata' : 'Quasi pronto'}</span>
            </div>
            <StatoChip text="In elaborazione" tint={T.warning} />
          </Card>
        )}
        <Card pad={12} style={{ position: 'relative', opacity: ready ? 1 : 0.45, transition: 'opacity .4s' }}>
          <image-slot id="acro-ortho" style={{ display: 'block', width: '100%', height: 150, borderRadius: 12 }}
            shape="rounded" radius="12" placeholder="Drop facade_ortho.png"></image-slot>
          <div style={{ position: 'absolute', left: 20, bottom: 20, display: 'flex', gap: 6 }}>
            <span style={{ font: `600 11px ${T.mono}`, color: '#fff', background: 'rgba(15,30,72,.78)', padding: '3px 8px', borderRadius: 6 }}>8.3 mm/px</span>
          </div>
        </Card>
        {ready && <>
          <div style={{ display: 'flex', gap: 12 }}>
            <MetricCard label="Area lorda" value={`${(rilievo.areaLorda || 0).toFixed(1)} m²`} />
            <MetricCard label="Area netta" value={`${(rilievo.areaNetta || 0).toFixed(1)} m²`} highlight />
            <MetricCard label="Aperture" value={String(rilievo.aperture.length)} />
          </div>
          <Card>
            <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>Aperture</span>
              <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 4, color: T.navy, font: `600 12px ${T.font}` }}><Icon name="plus" size={14} stroke={2.4} />Aggiungi</span>
            </div>
            {rilievo.aperture.map((a, i) => (
              <div key={i}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 0, padding: '6px 0' }}>
                  <span style={{ width: 28, color: T.navy, display: 'inline-flex' }}><Icon name={a.tipo === 'finestra' ? 'window' : 'door'} size={20} stroke={2} /></span>
                  <span style={{ font: `400 14px ${T.font}`, color: T.navy, textTransform: 'capitalize' }}>{a.tipo}</span>
                  <span style={{ marginLeft: 'auto', font: `500 12px ${T.font}`, color: T.muted }}>{a.area.toFixed(2)} m²</span>
                </div>
                {i < rilievo.aperture.length - 1 && <div style={{ height: 1, background: T.hair }} />}
              </div>
            ))}
          </Card>
          <div style={{ display: 'flex', gap: 10 }}>
            <BrandButton title="Editor 3D" icon="box" kind="secondary" onClick={() => go({ id: '3.2' })} style={{ minHeight: 46 }} />
            <BrandButton title="Rettifica" icon="grid" kind="secondary" onClick={() => go({ id: '3.4' })} style={{ minHeight: 46 }} />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <BrandButton title="Definisci facciata (4 tap)" icon="viewfinder" kind="primary" onClick={() => go({ id: '4.1' })} />
            <BrandButton title="Imposta scala (2 tap)" icon="ruler" kind="secondary" onClick={() => go({ id: '3.5' })} />
            <BrandButton title="Genera preventivo" icon="doc" kind="ghost" onClick={() => go({ id: '5.2' })} />
          </div>
        </>}
      </div>
    </ScreenScroll>
  );
}

// ── 3.2 Editor 3D mesh (dark, iPhone + iPad) ─────────────────────────────
function Editor3D({ go, pad = false }) {
  const [tool, setTool] = useState('box');
  const tools = [
    { id: 'box', icon: 'box', label: 'Box lavoro' },
    { id: 'lasso', icon: 'lasso', label: 'Lazo cancella' },
    { id: 'brush', icon: 'brush', label: 'Pennello facce' },
    { id: 'piano', icon: 'grid', label: 'Piano-zero (3 punti)' },
    { id: 'snap', icon: 'viewfinder', label: 'Snap vertici' },
  ];
  const active = tools.find(x => x.id === tool);
  const topY = pad ? 34 : 54;
  // mesh: perspective facade + wireframe + vertices
  const verts = [[12, 18], [34, 15], [58, 13], [84, 16], [12, 46], [34, 44], [58, 42], [84, 45], [12, 78], [34, 76], [58, 75], [84, 78]];
  return (
    <div style={{ position: 'absolute', inset: 0, background: '#0b0f1c', overflow: 'hidden' }}>
      {/* mesh viewport */}
      <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', perspective: 900 }}>
        <div style={{ position: 'relative', width: pad ? '62%' : '86%', height: pad ? '64%' : '46%', transform: 'rotateY(-16deg) rotateX(4deg)', borderRadius: 6, overflow: 'hidden', boxShadow: '0 30px 80px rgba(0,0,0,0.6)' }}>
          <FacadeBackdrop cols={7} rows={4} tone="#7d7466" />
          {/* wireframe */}
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }}>
            {[0, 1, 2].map(r => [0, 1, 2, 3].map(c => (
              <g key={`${r}${c}`} stroke="rgba(245,220,15,0.55)" strokeWidth="0.35" fill="none">
                <path d={`M${verts[r * 4 + c][0]} ${verts[r * 4 + c][1]} L${(verts[r * 4 + c + 1] || verts[r * 4 + c])[0]} ${(verts[r * 4 + c + 1] || verts[r * 4 + c])[1]}`} />
                {r < 2 && <path d={`M${verts[r * 4 + c][0]} ${verts[r * 4 + c][1]} L${verts[(r + 1) * 4 + c][0]} ${verts[(r + 1) * 4 + c][1]}`} />}
                {r < 2 && c < 3 && <path d={`M${verts[r * 4 + c][0]} ${verts[r * 4 + c][1]} L${verts[(r + 1) * 4 + c + 1][0]} ${verts[(r + 1) * 4 + c + 1][1]}`} />}
              </g>
            )))}
            {verts.map((v, i) => <circle key={i} cx={v[0]} cy={v[1]} r="0.9" fill={T.yellow} />)}
          </svg>
          {/* box lavoro */}
          {tool === 'box' && <div style={{ position: 'absolute', left: '10%', top: '12%', right: '14%', bottom: '18%', border: `2px dashed ${T.yellow}`, borderRadius: 4, background: 'rgba(245,220,15,0.07)' }} />}
        </div>
      </div>
      {/* top chrome */}
      <div style={{ position: 'absolute', top: topY, left: 16, right: 16, display: 'flex', alignItems: 'center', justifyContent: 'space-between', zIndex: 10 }}>
        <GlassCircle icon="x" onClick={() => go({ id: '3.1' })} />
        <GlassPill><span style={{ font: `600 14px ${T.font}` }}>Editor mesh</span></GlassPill>
        <GlassCircle icon="rotate" />
      </div>
      <div style={{ position: 'absolute', top: topY + 56, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 10 }}>
        <GlassPill style={{ padding: '5px 12px' }}><span style={{ font: `600 12px ${T.mono}` }}>12.4k vertici · 24.1k facce</span></GlassPill>
      </div>
      {/* tool label */}
      <div style={{ position: 'absolute', bottom: pad ? 132 : 178, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 10 }}>
        <GlassPill style={{ padding: '5px 12px' }}><span style={{ font: `600 12px ${T.font}`, color: T.yellow }}>{active.label}</span></GlassPill>
      </div>
      {/* toolbar */}
      <div style={{ position: 'absolute', bottom: pad ? 70 : 112, left: 0, right: 0, display: 'flex', justifyContent: 'center', gap: 12, zIndex: 10 }}>
        {tools.map(x => (
          <button key={x.id} onClick={() => setTool(x.id)} style={{
            width: 48, height: 48, borderRadius: '50%',
            border: x.id === tool ? `2px solid ${T.yellow}` : '0.5px solid rgba(255,255,255,0.18)',
            background: x.id === tool ? 'rgba(245,220,15,0.18)' : 'rgba(255,255,255,0.14)',
            backdropFilter: 'blur(10px)', WebkitBackdropFilter: 'blur(10px)',
            color: x.id === tool ? T.yellow : '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
          }}><Icon name={x.icon} size={20} stroke={2.1} /></button>
        ))}
      </div>
      {/* confirm */}
      <div style={{ position: 'absolute', bottom: pad ? 16 : 44, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 10 }}>
        <button onClick={() => go({ id: '3.4' })} style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '13px 26px', borderRadius: 999, background: T.yellow, color: T.navy, border: 'none', font: `600 16px ${T.font}`, cursor: 'pointer', boxShadow: '0 0 10px rgba(245,220,15,.4)' }}>
          <Icon name="check" size={17} stroke={2.6} />Conferma mesh
        </button>
      </div>
    </div>
  );
}

// ── 3.4 Rettifica facciata ───────────────────────────────────────────────
function Rettifica({ go }) {
  const [done, setDone] = useState(false);
  const H = (x, y) => (
    <span style={{ position: 'absolute', left: `${x}%`, top: `${y}%`, width: 22, height: 22, borderRadius: '50%', background: T.yellow, border: '3px solid #fff', boxShadow: '0 2px 8px rgba(0,0,0,0.4)', transform: 'translate(-50%,-50%)', zIndex: 3 }} />
  );
  return (
    <ScreenScroll>
      <NavBar title="Rettifica facciata" onBack={() => go({ id: '3.1' })} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 16px 40px' }}>
        <Card pad={12}>
          <div style={{ position: 'relative', height: 320, borderRadius: 12, overflow: 'hidden', background: '#2a2620', perspective: 700 }}>
            <div style={{ position: 'absolute', inset: '8% 10%', transform: done ? 'none' : 'rotateY(-14deg) rotateX(3deg) skewY(-2deg)', transition: 'transform .6s ease', borderRadius: 4, overflow: 'hidden' }}>
              <FacadeBackdrop rows={4} cols={5} tone="#948a7a" />
            </div>
            {!done && <>
              {H(12, 10)}{H(88, 16)}{H(10, 92)}{H(90, 86)}
              <svg viewBox="0 0 100 100" preserveAspectRatio="none" style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', zIndex: 2 }}>
                <path d="M12 10 L88 16 L90 86 L10 92 Z" fill="none" stroke={T.yellow} strokeWidth="0.5" strokeDasharray="2 1.4" />
              </svg>
            </>}
            {done && <div style={{ position: 'absolute', top: 12, left: 12, zIndex: 3 }}>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, font: `600 12px ${T.font}`, color: '#fff', background: T.success, padding: '5px 10px', borderRadius: 999 }}>
                <Icon name="check" size={13} stroke={3} />Ortofoto generata
              </span>
            </div>}
          </div>
        </Card>
        <div style={{ font: `400 14px ${T.font}`, color: T.muted, textAlign: 'center', padding: '0 12px' }}>
          {done ? 'Prospettiva raddrizzata. Ora imposta la scala reale.' : 'Trascina gli angoli sui vertici della facciata, poi raddrizza.'}
        </div>
        {!done
          ? <BrandButton title="Raddrizza → ortofoto" icon="grid" onClick={() => setDone(true)} />
          : <BrandButton title="Continua — Imposta scala" icon="ruler" onClick={() => go({ id: '3.5' })} />}
        <BrandButton title="Rifai da capo" kind="ghost" onClick={() => setDone(false)} />
      </div>
    </ScreenScroll>
  );
}

// ── 3.5 Misura scala ─────────────────────────────────────────────────────
function MisuraScala({ go }) {
  const [len, setLen] = useState('4.50');
  const ppm = (parseFloat(len.replace(',', '.')) || 0) > 0 ? (4500 / ((parseFloat(len.replace(',', '.')) || 1) * 120)).toFixed(1) : '—';
  return (
    <ScreenScroll>
      <NavBar title="Imposta scala" onBack={() => go({ id: '3.1' })} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 16px 40px' }}>
        <Card pad={12}>
          <div style={{ position: 'relative', height: 240, borderRadius: 12, overflow: 'hidden' }}>
            <FacadeBackdrop rows={4} cols={6} tone="#948a7a" />
            {/* measure line: 2 tap */}
            <svg viewBox="0 0 100 100" preserveAspectRatio="none" style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }}>
              <line x1="22" y1="62" x2="63" y2="62" stroke={T.yellow} strokeWidth="0.9" />
              <line x1="22" y1="58" x2="22" y2="66" stroke={T.yellow} strokeWidth="0.9" />
              <line x1="63" y1="58" x2="63" y2="66" stroke={T.yellow} strokeWidth="0.9" />
            </svg>
            <span style={{ position: 'absolute', left: '42.5%', top: '52%', transform: 'translateX(-50%)', font: `600 12px ${T.mono}`, color: T.navy, background: T.yellow, padding: '2px 8px', borderRadius: 6 }}>{len} m</span>
            <span style={{ position: 'absolute', left: 12, top: 12, font: `600 11px ${T.font}`, color: '#fff', background: 'rgba(15,30,72,.78)', padding: '4px 9px', borderRadius: 6 }}>2 di 2 punti</span>
          </div>
        </Card>
        <div style={{ font: `400 14px ${T.font}`, color: T.muted, textAlign: 'center', padding: '0 12px' }}>
          Tocca i due estremi di una misura nota (es. larghezza portone), poi inserisci la lunghezza reale.
        </div>
        <Card style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <Field label="Lunghezza reale" icon="ruler" value={len} suffix="m" onChange={setLen} />
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <span style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Scala risultante</span>
            <span style={{ marginLeft: 'auto', font: `600 15px ${T.mono}`, color: T.navy }}>{ppm} mm/px</span>
          </div>
        </Card>
        <BrandButton title="Conferma scala" icon="check" onClick={() => go({ id: '4.1' })} />
      </div>
    </ScreenScroll>
  );
}

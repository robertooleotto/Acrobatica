// Acrobatica Prototype — Fasi 4–5 (Marcatura, Preventivo)

// ── 4.1 Marcatura facciata (zone + aperture) ─────────────────────────────
function Marcatura({ rilievo, go }) {
  const [mode, setMode] = useState('zona');
  const modes = [
    { id: 'zona', label: 'Zona lavoro', icon: 'viewfinder' },
    { id: 'finestra', label: 'Finestra', icon: 'window' },
    { id: 'porta', label: 'Porta', icon: 'door' },
    { id: 'balcone', label: 'Balcone', icon: 'minus' },
  ];
  const zone = 'rgba(245,220,15,0.28)';
  const apert = 'rgba(15,30,72,0.45)';
  return (
    <ScreenScroll>
      <NavBar title="Marcatura facciata" onBack={() => go({ id: '3.1' })} trailing={
        <span style={{ color: T.navy, padding: 4, display: 'inline-flex' }}><Icon name="undo" size={20} stroke={2.1} /></span>} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14, padding: '8px 16px 40px' }}>
        <Card pad={12}>
          <div style={{ position: 'relative', height: 330, borderRadius: 12, overflow: 'hidden' }}>
            <FacadeBackdrop rows={5} cols={5} tone="#948a7a" />
            {/* zone di lavoro */}
            <div style={{ position: 'absolute', left: '6%', top: '8%', width: '88%', height: '52%', background: zone, border: `2px dashed ${T.yellow}`, borderRadius: 4 }}>
              <span style={{ position: 'absolute', top: 6, left: 6, font: `600 10px ${T.mono}`, color: T.navy, background: T.yellow, padding: '2px 6px', borderRadius: 4 }}>Z1 · 258.4 m²</span>
            </div>
            <div style={{ position: 'absolute', left: '6%', top: '66%', width: '56%', height: '26%', background: zone, border: `2px dashed ${T.yellow}`, borderRadius: 4 }}>
              <span style={{ position: 'absolute', top: 6, left: 6, font: `600 10px ${T.mono}`, color: T.navy, background: T.yellow, padding: '2px 6px', borderRadius: 4 }}>Z2 · 149.8 m²</span>
            </div>
            {/* aperture */}
            <div style={{ position: 'absolute', left: '14%', top: '20%', width: '13%', height: '14%', background: apert, border: '1.5px solid #fff', borderRadius: 3 }} />
            <div style={{ position: 'absolute', left: '44%', top: '20%', width: '13%', height: '14%', background: apert, border: '1.5px solid #fff', borderRadius: 3 }} />
            <div style={{ position: 'absolute', left: '70%', top: '70%', width: '12%', height: '24%', background: apert, border: '1.5px solid #fff', borderRadius: 3 }}>
              <span style={{ position: 'absolute', bottom: 4, left: '50%', transform: 'translateX(-50%)', font: `600 9px ${T.mono}`, color: '#fff', whiteSpace: 'nowrap' }}>porta</span>
            </div>
            <span style={{ position: 'absolute', right: 10, bottom: 10, font: `600 11px ${T.mono}`, color: '#fff', background: 'rgba(15,30,72,.78)', padding: '3px 8px', borderRadius: 6 }}>8.3 mm/px</span>
          </div>
        </Card>
        {/* strumenti */}
        <div style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingBottom: 2 }}>
          {modes.map(m => (
            <button key={m.id} onClick={() => setMode(m.id)} style={{
              display: 'inline-flex', alignItems: 'center', gap: 6, padding: '9px 14px', borderRadius: 999,
              border: m.id === mode ? 'none' : `1px solid ${T.hair2}`,
              background: m.id === mode ? T.navy : T.white, color: m.id === mode ? T.yellow : T.navy,
              font: `600 13px ${T.font}`, cursor: 'pointer', whiteSpace: 'nowrap', flex: 'none',
            }}><Icon name={m.icon} size={15} stroke={2.2} />{m.label}</button>
          ))}
        </div>
        <div style={{ display: 'flex', gap: 12 }}>
          <MetricCard label="Area lorda" value="491.4 m²" />
          <MetricCard label="Area netta" value="408.2 m²" highlight />
          <MetricCard label="Aperture" value="3" />
        </div>
        <BrandButton title="Genera preventivo" icon="doc" onClick={() => go({ id: '5.2' })} />
      </div>
    </ScreenScroll>
  );
}

// ── 5.1 Preventivi (lista + filtro) ──────────────────────────────────────
function PreventiviList({ preventivi, go }) {
  const [filtro, setFiltro] = useState('Tutti');
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const filtered = filtro === 'Tutti' ? preventivi : preventivi.filter(p => p.stato === ({ Bozze: 'Bozza', Inviati: 'Inviato', Accettati: 'Accettato' })[filtro]);
  return (
    <ScreenScroll tabbed>
      <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', padding: '58px 16px 8px' }}>
        <h1 style={{ margin: 0, font: `700 34px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Preventivi</h1>
        <button style={{ border: 'none', background: 'none', cursor: 'pointer', padding: 6, color: T.navy }}>
          <Icon name="plus" size={24} stroke={2.4} />
        </button>
      </div>
      <div style={{ padding: '4px 16px 12px' }}>
        <Segmented small options={['Tutti', 'Bozze', 'Inviati', 'Accettati']} value={filtro} onChange={setFiltro} />
      </div>
      {filtered.length === 0 ? (
        <EmptyState icon="doc" title="Nessun preventivo" subtitle={filtro === 'Tutti' ? 'Genera un preventivo da un rilievo elaborato' : `Nessun preventivo con stato "${filtro.slice(0, -1)}${filtro === 'Bozze' ? 'a' : 'o'}"`} />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '0 16px 40px' }}>
          {filtered.map(p => (
            <Card key={p.numero} onClick={() => go({ id: '5.2', preventivo: p.numero })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <Tile icon="doc" size={48} bg={T.grayBg} color={'rgba(15,30,72,0.5)'} glyph={20} />
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
                <span style={{ font: `600 15px ${T.mono}`, color: T.navy }}>{p.numero}</span>
                <span style={{ font: `400 13px ${T.font}`, color: T.muted, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.cliente}</span>
              </div>
              <div style={{ marginLeft: 'auto', display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5, flex: 'none' }}>
                <span style={{ font: `700 15px ${T.mono}`, color: T.navy }}>{eur(p.totale)}</span>
                <StatoChip text={p.stato} tint={statoTint(p.stato)} />
              </div>
            </Card>
          ))}
        </div>
      )}
    </ScreenScroll>
  );
}

// ── 5.2 Preventivo / Editor + anteprima ──────────────────────────────────
function PreventivoEditor({ preventivo, voci, go }) {
  const imponibile = voci.reduce((s, v) => s + v.q * v.p, 0) + preventivo.ore * preventivo.tariffa;
  const iva = imponibile * 0.22;
  const tot = imponibile + iva;
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (
    <ScreenScroll>
      <NavBar title={preventivo.numero} onBack={() => go({ id: '5.1' })} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 16px 40px' }}>
        <Card>
          <div style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Cliente</div>
          <div style={{ font: `600 18px ${T.font}`, color: T.navy, margin: '6px 0 8px' }}>{preventivo.cliente}</div>
          <div style={{ height: 1, background: T.hair, margin: '0 0 8px' }} />
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <StatoChip text={preventivo.stato || 'Bozza'} tint={statoTint(preventivo.stato || 'Bozza')} />
            <span style={{ marginLeft: 'auto', font: `500 12px ${T.font}`, color: T.muted }}>Validità: 30 giorni</span>
          </div>
        </Card>
        <Card>
          <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
            <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>Voci di lavoro</span>
            <button onClick={() => go({ id: '6.3', select: true })} style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 4, color: T.navy, font: `600 12px ${T.font}`, border: 'none', background: 'none', cursor: 'pointer', padding: 2 }}>
              <Icon name="tag" size={14} stroke={2.2} />Aggiungi da listino
            </button>
          </div>
          {voci.map((v, i) => (
            <div key={i} style={{ background: T.grayBg, borderRadius: 12, padding: 10, marginBottom: 8 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
                <span style={{ font: `600 15px ${T.font}`, color: T.navy, flex: 1 }}>{v.desc}</span>
                <Icon name="pencil" size={14} color={T.muted} stroke={2} />
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, font: `400 13px ${T.font}`, color: T.muted }}>
                <span>{v.q} {v.unita}</span><span>×</span><span>{eur(v.p)}</span>
                <span style={{ marginLeft: 'auto', font: `600 13px ${T.font}`, color: T.navy }}>= {eur(v.q * v.p)}</span>
              </div>
            </div>
          ))}
        </Card>
        <Card>
          <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
            <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>Manodopera</span>
          </div>
          <div style={{ background: T.grayBg, borderRadius: 12, padding: 10, display: 'flex', alignItems: 'center', gap: 8, font: `400 13px ${T.font}`, color: T.muted }}>
            <Icon name="user" size={15} stroke={2} />
            <span>{preventivo.ore} h</span><span>×</span><span>{eur(preventivo.tariffa)}/h</span>
            <span style={{ marginLeft: 'auto', font: `600 13px ${T.font}`, color: T.navy }}>= {eur(preventivo.ore * preventivo.tariffa)}</span>
          </div>
        </Card>
        <Card style={{ background: 'rgba(245,220,15,0.18)', borderColor: T.yellow }}>
          <Row label="Imponibile" value={eur(imponibile)} />
          <Row label="IVA 22%" value={eur(iva)} />
          <div style={{ height: 1, background: T.hair2, margin: '8px 0' }} />
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <span style={{ font: `700 14px ${T.font}`, color: T.navy }}>TOTALE</span>
            <span style={{ marginLeft: 'auto', font: `700 22px ${T.font}`, color: T.navy }}>{eur(tot)}</span>
          </div>
        </Card>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <BrandButton title="Anteprima PDF" icon="doc" kind="secondary" onClick={() => go({ id: '5.4' })} />
          <BrandButton title="Firma cliente" icon="signature" kind="primary" onClick={() => go({ id: '5.5' })} />
        </div>
      </div>
    </ScreenScroll>
  );
}

function Row({ label, value }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', padding: '3px 0' }}>
      <span style={{ font: `400 14px ${T.font}`, color: T.muted }}>{label}</span>
      <span style={{ marginLeft: 'auto', font: `600 14px ${T.font}`, color: T.navy }}>{value}</span>
    </div>
  );
}

// ── 5.4 PDF preventivo ───────────────────────────────────────────────────
function PDFPreventivo({ preventivo, voci, go }) {
  const imponibile = voci.reduce((s, v) => s + v.q * v.p, 0) + preventivo.ore * preventivo.tariffa;
  const tot = imponibile * 1.22;
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const line = (l, r, bold) => (
    <div style={{ display: 'flex', font: `${bold ? 600 : 400} 9px ${T.font}`, color: bold ? T.navy : 'rgba(15,30,72,0.7)', padding: '2.5px 0' }}>
      <span>{l}</span><span style={{ marginLeft: 'auto', fontFamily: T.mono }}>{r}</span>
    </div>
  );
  return (
    <ScreenScroll>
      <NavBar title="Anteprima PDF" onBack={() => go({ id: '5.2' })} trailing={
        <span style={{ color: T.navy, padding: 4, display: 'inline-flex' }}><Icon name="share" size={20} stroke={2.1} /></span>} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 16px 40px' }}>
        {/* pagina A4 */}
        <div style={{ background: '#fff', borderRadius: 8, border: `1px solid ${T.hair2}`, boxShadow: '0 12px 30px rgba(15,30,72,0.10)', padding: '22px 20px', aspectRatio: '1/1.414', display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <Wordmark size={20} word={12} />
            <span style={{ marginLeft: 'auto', font: `600 9px ${T.mono}`, color: T.muted }}>{preventivo.numero}</span>
          </div>
          <div style={{ height: 2, background: T.yellow }} />
          <div style={{ display: 'flex', gap: 16 }}>
            <div style={{ flex: 1 }}>
              <div style={{ font: `600 7px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Cliente</div>
              <div style={{ font: `600 10px ${T.font}`, color: T.navy, marginTop: 2 }}>{preventivo.cliente}</div>
              <div style={{ font: `400 8px ${T.font}`, color: T.muted }}>Via Garibaldi 14, Milano</div>
            </div>
            <div>
              <div style={{ font: `600 7px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Data</div>
              <div style={{ font: `500 9px ${T.mono}`, color: T.navy, marginTop: 2 }}>04/07/2026</div>
            </div>
          </div>
          <div style={{ font: `700 11px ${T.font}`, color: T.navy, marginTop: 4 }}>Preventivo — Rilievo e tinteggiatura facciata Nord</div>
          <div style={{ borderTop: `1px solid ${T.hair2}`, paddingTop: 6 }}>
            {voci.map((v, i) => line(`${v.desc} — ${v.q} ${v.unita} × ${eur(v.p)}`, eur(v.q * v.p)))}
            {line(`Manodopera — ${preventivo.ore} h × ${eur(preventivo.tariffa)}`, eur(preventivo.ore * preventivo.tariffa))}
          </div>
          <div style={{ marginTop: 'auto', borderTop: `1px solid ${T.hair2}`, paddingTop: 6 }}>
            {line('Imponibile', eur(imponibile))}
            {line('IVA 22%', eur(imponibile * 0.22))}
            <div style={{ display: 'flex', background: 'rgba(245,220,15,0.25)', borderRadius: 4, padding: '4px 6px', marginTop: 3 }}>
              <span style={{ font: `700 10px ${T.font}`, color: T.navy }}>TOTALE</span>
              <span style={{ marginLeft: 'auto', font: `700 10px ${T.mono}`, color: T.navy }}>{eur(tot)}</span>
            </div>
            <div style={{ display: 'flex', gap: 20, marginTop: 12 }}>
              <div style={{ flex: 1 }}>
                <div style={{ height: 16, borderBottom: `1px solid ${T.hair2}` }} />
                <div style={{ font: `400 7px ${T.font}`, color: T.muted, marginTop: 2 }}>Firma dell'impresa</div>
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ height: 16, borderBottom: `1px solid ${T.hair2}` }} />
                <div style={{ font: `400 7px ${T.font}`, color: T.muted, marginTop: 2 }}>Firma del cliente</div>
              </div>
            </div>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <BrandButton title="Condividi PDF" icon="share" kind="secondary" />
          <BrandButton title="Firma cliente" icon="signature" onClick={() => go({ id: '5.5' })} />
        </div>
      </div>
    </ScreenScroll>
  );
}

// ── 5.5 Firma cliente ────────────────────────────────────────────────────
function FirmaCliente({ preventivo, go }) {
  const [strokes, setStrokes] = useState([]);
  const [accepted, setAccepted] = useState(false);
  const drawing = useRef(false);
  const boxRef = useRef(null);
  const pt = e => {
    const r = boxRef.current.getBoundingClientRect();
    return [((e.clientX - r.left) / r.width * 100).toFixed(1), ((e.clientY - r.top) / r.height * 100).toFixed(1)];
  };
  const down = e => { drawing.current = true; setStrokes(s => [...s, [pt(e)]]); e.currentTarget.setPointerCapture(e.pointerId); };
  const move = e => { if (!drawing.current) return; setStrokes(s => { const c = s.slice(); c[c.length - 1] = [...c[c.length - 1], pt(e)]; return c; }); };
  const up = () => { drawing.current = false; };
  const has = strokes.some(s => s.length > 2);

  if (accepted) {
    return (
      <ScreenScroll>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 14, minHeight: '100%', padding: '80px 32px', textAlign: 'center', boxSizing: 'border-box' }}>
          <div style={{ width: 88, height: 88, borderRadius: '50%', background: 'rgba(31,164,99,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="check" size={42} color={T.success} stroke={2.4} />
          </div>
          <div style={{ font: `700 24px ${T.font}`, color: T.navy }}>Preventivo accettato</div>
          <div style={{ font: `400 15px ${T.font}`, color: T.muted, maxWidth: 260 }}>
            {preventivo.numero} firmato dal cliente. Una copia PDF è stata inviata via email.
          </div>
          <div style={{ width: '100%', maxWidth: 280, display: 'flex', flexDirection: 'column', gap: 10, marginTop: 16 }}>
            <BrandButton title="Torna ai preventivi" onClick={() => go({ id: '5.1' })} />
            <BrandButton title="Vai al cantiere" kind="ghost" onClick={() => go({ id: '1.4' })} />
          </div>
        </div>
      </ScreenScroll>
    );
  }
  return (
    <ScreenScroll>
      <NavBar title="Firma cliente" onBack={() => go({ id: '5.2' })} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 16px 40px' }}>
        <Card>
          <div style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Accettazione</div>
          <div style={{ font: `400 14px ${T.font}`, color: T.navy, marginTop: 6, lineHeight: 1.45 }}>
            Firmando accetti il preventivo <b style={{ fontFamily: T.mono }}>{preventivo.numero}</b> per un totale di <b>€ 11.416,27</b> IVA inclusa.
          </div>
        </Card>
        <Card pad={0} style={{ overflow: 'hidden' }}>
          <div ref={boxRef} onPointerDown={down} onPointerMove={move} onPointerUp={up}
            style={{ position: 'relative', height: 240, background: T.white, touchAction: 'none', cursor: 'crosshair' }}>
            <div style={{ position: 'absolute', left: 24, right: 24, bottom: 48, borderBottom: `1.5px dashed ${T.hair2}` }} />
            <span style={{ position: 'absolute', left: 24, bottom: 26, font: `400 12px ${T.font}`, color: T.muted }}>✕ Firma qui</span>
            {!has && <span style={{ position: 'absolute', top: '38%', left: 0, right: 0, textAlign: 'center', font: `400 14px ${T.font}`, color: 'rgba(15,30,72,0.3)', pointerEvents: 'none' }}>Firma con il dito</span>}
            <svg viewBox="0 0 100 100" preserveAspectRatio="none" style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', pointerEvents: 'none' }}>
              {strokes.map((s, i) => <polyline key={i} points={s.map(p => p.join(',')).join(' ')} fill="none" stroke={T.navy} strokeWidth="0.8" strokeLinecap="round" strokeLinejoin="round" />)}
            </svg>
          </div>
        </Card>
        <div style={{ display: 'flex', gap: 10 }}>
          <BrandButton title="Cancella" kind="ghost" onClick={() => setStrokes([])} style={{ flex: 1 }} />
          <BrandButton title="Conferma accettazione" icon="check" disabled={!has} onClick={() => setAccepted(true)} style={{ flex: 2 }} />
        </div>
      </div>
    </ScreenScroll>
  );
}

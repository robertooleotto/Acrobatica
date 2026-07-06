// Acrobatica Prototype — Fase 0 (Accesso) + Fase 6 (Anagrafiche) — schermate 🆕 con varianti

// ── 0.1 Splash ───────────────────────────────────────────────────────────
function Splash({ go, variant = 'A' }) {
  useEffect(() => { const t = setTimeout(() => go({ id: '0.2' }), 2400); return () => clearTimeout(t); }, []);
  if (variant === 'B') {
    return (
      <div onClick={() => go({ id: '0.2' })} style={{ position: 'absolute', inset: 0, background: T.paper, display: 'flex', flexDirection: 'column', cursor: 'pointer' }}>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'flex-start', justifyContent: 'flex-end', padding: '0 28px 28px' }}>
          <div style={{ width: 64, height: 64, borderRadius: 18, background: T.navy, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="building" size={34} color={T.yellow} />
          </div>
          <div style={{ font: `700 44px ${T.font}`, color: T.navy, letterSpacing: '-.02em', marginTop: 18 }}>Acrobatica</div>
          <div style={{ font: `400 16px ${T.font}`, color: T.muted, marginTop: 6 }}>Rilievi di facciata dal suolo</div>
        </div>
        <div style={{ background: T.yellow, padding: '22px 28px 54px' }}>
          <div style={{ height: 4, borderRadius: 999, background: 'rgba(15,30,72,0.18)', overflow: 'hidden' }}>
            <div style={{ height: '100%', width: '60%', borderRadius: 999, background: T.navy, animation: 'acro-load 2.2s ease forwards' }} />
          </div>
          <div style={{ display: 'flex', marginTop: 10, font: `500 12px ${T.font}`, color: T.navy }}>
            <span>Caricamento…</span><span style={{ marginLeft: 'auto', fontFamily: T.mono }}>v2.4.0</span>
          </div>
        </div>
      </div>
    );
  }
  return (
    <div onClick={() => go({ id: '0.2' })} style={{ position: 'absolute', inset: 0, background: T.navy, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 20, cursor: 'pointer' }}>
      <div style={{ width: 84, height: 84, borderRadius: 24, background: T.yellow, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon name="building" size={44} color={T.navy} />
      </div>
      <div style={{ font: `700 32px ${T.font}`, color: '#fff', letterSpacing: '-.01em' }}>Acrobatica</div>
      <span style={{ width: 26, height: 26, borderRadius: '50%', border: '3px solid rgba(255,255,255,0.18)', borderTopColor: T.yellow, animation: 'acro-spin .9s linear infinite', marginTop: 12 }} />
      <span style={{ position: 'absolute', bottom: 48, font: `500 12px ${T.mono}`, color: 'rgba(255,255,255,0.45)' }}>v2.4.0</span>
    </div>
  );
}

// ── 0.2 Login ────────────────────────────────────────────────────────────
function Login({ go, variant = 'A' }) {
  const [email, setEmail] = useState('carlo@impresaedile.it');
  const [pwd, setPwd] = useState('');
  const [ruolo, setRuolo] = useState('Operatore');
  const [err, setErr] = useState(false);
  const [loading, setLoading] = useState(false);
  const submit = () => {
    if (!pwd) { setErr(true); return; }
    setErr(false); setLoading(true);
    setTimeout(() => go({ id: '0.3' }), 1000);
  };
  const form = (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <Field label="Email" icon="mail" value={email} onChange={setEmail} />
      <Field label="Password" icon="lock" secure value={pwd} onChange={v => { setPwd(v); if (v) setErr(false); }}
        error={err ? 'Inserisci la password per continuare' : null} placeholder="••••••••" />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <span style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted }}>Ruolo</span>
        <Segmented options={['Operatore', 'Senior']} value={ruolo} onChange={setRuolo} />
      </div>
      <button onClick={submit} disabled={loading} style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
        width: '100%', minHeight: 52, borderRadius: 22, border: 'none',
        background: T.yellow, color: T.navy, font: `600 17px ${T.font}`, cursor: 'pointer', marginTop: 4,
      }}>
        {loading
          ? <span style={{ width: 20, height: 20, borderRadius: '50%', border: '3px solid rgba(15,30,72,0.2)', borderTopColor: T.navy, animation: 'acro-spin .8s linear infinite' }} />
          : 'Accedi'}
      </button>
      <button style={{ border: 'none', background: 'none', cursor: 'pointer', color: T.muted, font: `500 13px ${T.font}`, padding: 6 }}>Password dimenticata?</button>
    </div>
  );
  if (variant === 'B') {
    return (
      <div style={{ position: 'absolute', inset: 0, background: T.navy, display: 'flex', flexDirection: 'column' }}>
        <div style={{ padding: '92px 28px 36px' }}>
          <Wordmark size={46} word={26} onNavy />
          <div style={{ font: `400 15px ${T.font}`, color: 'rgba(255,255,255,0.6)', marginTop: 14, lineHeight: 1.5 }}>
            Rilievo 3D e preventivi di facciata,<br />direttamente dal suolo.
          </div>
        </div>
        <div style={{ flex: 1, background: T.paper, borderRadius: '28px 28px 0 0', padding: '26px 20px 40px', overflowY: 'auto' }}>
          <div style={{ font: `700 22px ${T.font}`, color: T.navy, marginBottom: 16 }}>Accedi</div>
          {form}
        </div>
      </div>
    );
  }
  return (
    <ScreenScroll>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 22, padding: '84px 20px 40px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <div style={{ width: 64, height: 64, borderRadius: 18, background: T.yellow, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="building" size={32} color={T.navy} />
          </div>
          <div style={{ font: `700 26px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Acrobatica</div>
          <div style={{ font: `400 14px ${T.font}`, color: T.muted }}>Rilievi di facciata dal suolo</div>
        </div>
        <Card pad={18} radius={18}>{form}</Card>
      </div>
    </ScreenScroll>
  );
}

// ── 0.3 Home / Dashboard ─────────────────────────────────────────────────
function Home({ cantieri, preventivi, go, variant = 'A', onNuovoCantiere }) {
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const vuoto = cantieri.length === 0;
  const kpi = [
    { label: 'Cantieri attivi', value: String(cantieri.length) },
    { label: 'Da inviare', value: String(preventivi.filter(p => p.stato === 'Bozza').length) },
    { label: 'm² questo mese', value: vuoto ? '0' : '587' },
  ];
  const cantiereRow = c => (
    <Card key={c.id} radius={14} pad={12} onClick={() => go({ id: '1.4', cantiere: c.id })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <Tile icon="building" size={44} glyph={19} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
        <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>{c.nome}</span>
        <span style={{ font: `400 12px ${T.font}`, color: T.muted }}>{c.cliente}</span>
      </div>
      <div style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={16} stroke={2.2} /></div>
    </Card>
  );
  const prevRow = p => (
    <Card key={p.numero} radius={14} pad={12} onClick={() => go({ id: '5.2', preventivo: p.numero })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <Tile icon="doc" size={44} bg={T.grayBg} color={'rgba(15,30,72,0.5)'} glyph={18} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
        <span style={{ font: `600 13px ${T.mono}`, color: T.navy }}>{p.numero}</span>
        <StatoChip text={p.stato} tint={statoTint(p.stato)} />
      </div>
      <span style={{ marginLeft: 'auto', font: `700 14px ${T.mono}`, color: T.navy }}>{eur(p.totale)}</span>
    </Card>
  );
  const azioni = (
    <div style={{ display: 'flex', gap: 10 }}>
      <BrandButton title="Nuovo cantiere" icon="plus" onClick={onNuovoCantiere} />
      <BrandButton title="Nuovo rilievo" icon="camera" kind="secondary" onClick={() => go({ id: '2.1' })} />
    </div>
  );
  const saluto = <>
    <div style={{ font: `700 30px ${T.font}`, color: variant === 'B' ? '#fff' : T.navy, letterSpacing: '-.01em' }}>Ciao, Carlo</div>
    <div style={{ font: `400 14px ${T.font}`, color: variant === 'B' ? 'rgba(255,255,255,0.6)' : T.muted, marginTop: 2 }}>Venerdì 4 luglio</div>
  </>;

  if (vuoto) {
    return (
      <ScreenScroll tabbed>
        <div style={{ padding: '66px 16px 4px' }}>{saluto}</div>
        <EmptyState icon="building" title="Inizia da qui" subtitle="Crea il tuo primo cantiere per avviare un rilievo" cta="Crea il tuo primo cantiere" onCta={onNuovoCantiere} pad={70} />
      </ScreenScroll>
    );
  }

  if (variant === 'B') {
    return (
      <ScreenScroll tabbed>
        <div style={{ background: T.navy, borderRadius: '0 0 28px 28px', padding: '66px 16px 22px' }}>
          {saluto}
          <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
            {kpi.map(k => (
              <div key={k.label} style={{ flex: 1, background: 'rgba(255,255,255,0.08)', border: '1px solid rgba(255,255,255,0.12)', borderRadius: 14, padding: 12 }}>
                <div style={{ font: `700 22px ${T.font}`, color: T.yellow }}>{k.value}</div>
                <div style={{ font: `600 9px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: 'rgba(255,255,255,0.55)', marginTop: 3 }}>{k.label}</div>
              </div>
            ))}
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '16px 16px 40px' }}>
          {azioni}
          <SectionHeader title="Ultimi cantieri" action="Vedi tutti" onAction={() => go({ id: '1.1' })} />
          {cantieri.slice(0, 3).map(cantiereRow)}
          <SectionHeader title="Preventivi recenti" action="Vedi tutti" onAction={() => go({ id: '5.1' })} />
          {preventivi.slice(0, 2).map(prevRow)}
        </div>
      </ScreenScroll>
    );
  }
  if (variant === 'C') {
    return (
      <ScreenScroll tabbed>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '66px 16px 40px' }}>
          <div>{saluto}</div>
          <Card pad={18} radius={18} onClick={() => go({ id: '2.1' })} style={{ background: T.yellow, borderColor: T.yellow, display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ width: 54, height: 54, borderRadius: 16, background: T.navy, display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 'none' }}>
              <Icon name="camera" size={26} color={T.yellow} />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
              <span style={{ font: `700 18px ${T.font}`, color: T.navy }}>Nuovo rilievo</span>
              <span style={{ font: `400 13px ${T.font}`, color: 'rgba(15,30,72,0.65)' }}>Inquadra la facciata e scatta</span>
            </div>
            <div style={{ marginLeft: 'auto', color: T.navy }}><Icon name="chevron" size={20} stroke={2.4} /></div>
          </Card>
          <div style={{ display: 'flex', gap: 8 }}>
            {kpi.map(k => (
              <div key={k.label} style={{ flex: 1 }}>
                <div style={{ font: `700 20px ${T.mono}`, color: T.navy }}>{k.value}</div>
                <div style={{ font: `600 9px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted, marginTop: 2 }}>{k.label}</div>
              </div>
            ))}
          </div>
          <div style={{ height: 1, background: T.hair }} />
          <SectionHeader title="Cantieri" count={cantieri.length} action="Vedi tutti" onAction={() => go({ id: '1.1' })} />
          {cantieri.map(cantiereRow)}
          <BrandButton title="Nuovo cantiere" icon="plus" kind="ghost" onClick={onNuovoCantiere} />
        </div>
      </ScreenScroll>
    );
  }
  // variant A
  return (
    <ScreenScroll tabbed>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '66px 16px 40px' }}>
        <div>{saluto}</div>
        <div style={{ display: 'flex', gap: 12 }}>
          {kpi.map(k => <MetricCard key={k.label} label={k.label} value={k.value} highlight={k.label === 'Da inviare'} />)}
        </div>
        {azioni}
        <SectionHeader title="Ultimi cantieri" action="Vedi tutti" onAction={() => go({ id: '1.1' })} />
        {cantieri.slice(0, 3).map(cantiereRow)}
        <SectionHeader title="Preventivi recenti" action="Vedi tutti" onAction={() => go({ id: '5.1' })} />
        {preventivi.slice(0, 2).map(prevRow)}
      </div>
    </ScreenScroll>
  );
}

// ── helpers anagrafica ───────────────────────────────────────────────────
function initials(nome) {
  return nome.split(/\s+/).slice(0, 2).map(w => w[0]).join('').toUpperCase();
}
function AvatarInitials({ nome, size = 48, navy = true }) {
  return (
    <div style={{ width: size, height: size, borderRadius: size * 0.28, background: navy ? T.navy : T.grayBg, color: navy ? T.yellow : T.muted, display: 'flex', alignItems: 'center', justifyContent: 'center', font: `700 ${size * 0.36}px ${T.font}`, flex: 'none' }}>
      {initials(nome)}
    </div>
  );
}

// ── 6.1 Clienti / Lista ──────────────────────────────────────────────────
function ClientiList({ clienti, go, variant = 'A' }) {
  const [q, setQ] = useState('');
  const [sheet, setSheet] = useState(false);
  const rows = clienti.filter(c => c.nome.toLowerCase().includes(q.toLowerCase()));
  const row = c => (
    <Card key={c.id} radius={14} pad={12} onClick={() => go({ id: '6.2', cliente: c.id })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <AvatarInitials nome={c.nome} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
        <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>{c.nome}</span>
        <span style={{ font: `400 12px ${T.font}`, color: T.muted }}>{c.citta} · {c.nCantieri} cantier{c.nCantieri === 1 ? 'e' : 'i'}</span>
      </div>
      <div style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={16} stroke={2.2} /></div>
    </Card>
  );
  let body;
  if (rows.length === 0) {
    body = <EmptyState icon="users" title={q ? 'Nessun risultato' : 'Nessun cliente'} subtitle={q ? `Nessun cliente corrisponde a "${q}"` : 'Aggiungi il primo cliente per collegarlo a cantieri e preventivi'} cta={q ? null : 'Nuovo cliente'} onCta={() => setSheet(true)} />;
  } else if (variant === 'B') {
    const groups = {};
    rows.forEach(c => { const l = c.nome[0].toUpperCase(); (groups[l] = groups[l] || []).push(c); });
    body = (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '0 16px 40px' }}>
        {Object.keys(groups).sort().map(l => (
          <div key={l} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <span style={{ font: `700 13px ${T.mono}`, color: T.muted, padding: '8px 2px 0' }}>{l}</span>
            {groups[l].map(row)}
          </div>
        ))}
      </div>
    );
  } else {
    body = <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '0 16px 40px' }}>{rows.map(row)}</div>;
  }
  return (
    <ScreenScroll tabbed>
      <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', padding: '58px 16px 8px' }}>
        <h1 style={{ margin: 0, font: `700 34px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Clienti</h1>
        <button onClick={() => setSheet(true)} style={{ border: 'none', background: 'none', cursor: 'pointer', padding: 6, color: T.navy }}>
          <Icon name="plus" size={24} stroke={2.4} />
        </button>
      </div>
      <div style={{ padding: '4px 16px 14px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: T.grayBg, borderRadius: 12, padding: '0 12px', height: 42 }}>
          <Icon name="search" size={16} color={T.muted} stroke={2.2} />
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Cerca cliente"
            style={{ flex: 1, border: 'none', outline: 'none', background: 'none', font: `400 15px ${T.font}`, color: T.navy, minWidth: 0 }} />
        </div>
      </div>
      {body}
      {sheet && (
        <Sheet title="Nuovo cliente" onClose={() => setSheet(false)} cta="Salva cliente" onCta={() => setSheet(false)}>
          <Field label="Nome / Ragione sociale" placeholder="Es. Rossi Costruzioni S.r.l." />
          <div style={{ display: 'flex', gap: 10 }}>
            <div style={{ flex: 1 }}><Field label="Telefono" icon="phone" placeholder="+39…" /></div>
            <div style={{ flex: 1 }}><Field label="P.IVA" placeholder="IT…" /></div>
          </div>
          <Field label="Email" icon="mail" placeholder="nome@azienda.it" />
          <Field label="Indirizzo" icon="pin" placeholder="Via, numero, città" />
        </Sheet>
      )}
    </ScreenScroll>
  );
}

// ── 6.2 Cliente / Dettaglio ──────────────────────────────────────────────
function ClienteDettaglio({ cliente, cantieri, preventivi, go, variant = 'A' }) {
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const suoi = cantieri.filter(c => c.clienteId === cliente.id);
  const suoiPrev = preventivi.filter(p => p.clienteId === cliente.id);
  const contactCircle = (icon, label) => (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
      <button style={{ width: 48, height: 48, borderRadius: '50%', border: 'none', background: 'rgba(255,255,255,0.1)', color: T.yellow, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer' }}>
        <Icon name={icon} size={20} stroke={2.1} />
      </button>
      <span style={{ font: `500 11px ${T.font}`, color: 'rgba(255,255,255,0.65)' }}>{label}</span>
    </div>
  );
  const contactRow = (icon, value) => (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0' }}>
      <div style={{ width: 34, height: 34, borderRadius: 10, background: T.grayBg, display: 'flex', alignItems: 'center', justifyContent: 'center', color: T.navy }}>
        <Icon name={icon} size={16} stroke={2.1} />
      </div>
      <span style={{ font: `400 14px ${T.font}`, color: T.navy }}>{value}</span>
      <span style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={15} stroke={2.2} /></span>
    </div>
  );
  const liste = (
    <>
      <SectionHeader title="Cantieri" count={suoi.length} />
      {suoi.length === 0 && <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>Nessun cantiere per questo cliente.</span>}
      {suoi.map(c => (
        <Card key={c.id} radius={14} pad={12} onClick={() => go({ id: '1.4', cantiere: c.id })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <Tile icon="building" size={44} glyph={19} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            <span style={{ font: `600 15px ${T.font}`, color: T.navy }}>{c.nome}</span>
            <span style={{ font: `400 12px ${T.font}`, color: T.muted }}>{c.rilievi.length} facciat{c.rilievi.length === 1 ? 'a' : 'e'}</span>
          </div>
          <div style={{ marginLeft: 'auto', color: T.muted }}><Icon name="chevron" size={16} stroke={2.2} /></div>
        </Card>
      ))}
      <SectionHeader title="Preventivi" count={suoiPrev.length} />
      {suoiPrev.length === 0 && <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>Nessun preventivo per questo cliente.</span>}
      {suoiPrev.map(p => (
        <Card key={p.numero} radius={14} pad={12} onClick={() => go({ id: '5.2', preventivo: p.numero })} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <Tile icon="doc" size={44} bg={T.grayBg} color={'rgba(15,30,72,0.5)'} glyph={18} />
          <span style={{ font: `600 13px ${T.mono}`, color: T.navy }}>{p.numero}</span>
          <div style={{ marginLeft: 'auto', display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 4 }}>
            <span style={{ font: `700 14px ${T.mono}`, color: T.navy }}>{eur(p.totale)}</span>
            <StatoChip text={p.stato} tint={statoTint(p.stato)} />
          </div>
        </Card>
      ))}
      <BrandButton title="Nuovo cantiere per questo cliente" icon="plus" kind="secondary" onClick={() => go({ id: '1.2' })} />
    </>
  );
  if (variant === 'B') {
    return (
      <ScreenScroll>
        <div style={{ background: T.navy, borderRadius: '0 0 28px 28px', padding: '54px 16px 24px' }}>
          <div style={{ display: 'flex', alignItems: 'center' }}>
            <button onClick={() => go({ id: '6.1' })} style={{ border: 'none', background: 'rgba(255,255,255,0.1)', borderRadius: 999, width: 36, height: 36, display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer', color: '#fff' }}>
              <Icon name="back" size={18} stroke={2.2} />
            </button>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, marginTop: 8 }}>
            <div style={{ width: 72, height: 72, borderRadius: 22, background: T.yellow, color: T.navy, display: 'flex', alignItems: 'center', justifyContent: 'center', font: `700 26px ${T.font}` }}>{initials(cliente.nome)}</div>
            <div style={{ font: `700 22px ${T.font}`, color: '#fff', textAlign: 'center' }}>{cliente.nome}</div>
            <div style={{ font: `400 13px ${T.font}`, color: 'rgba(255,255,255,0.55)' }}>{cliente.indirizzo}</div>
            <div style={{ display: 'flex', gap: 22, marginTop: 8 }}>
              {contactCircle('phone', 'Chiama')}{contactCircle('mail', 'Email')}{contactCircle('pin', 'Mappa')}
            </div>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '16px 16px 40px' }}>{liste}</div>
      </ScreenScroll>
    );
  }
  return (
    <ScreenScroll>
      <NavBar title="Cliente" onBack={() => go({ id: '6.1' })} trailing={
        <span style={{ color: T.navy, padding: 4, display: 'inline-flex' }}><Icon name="pencil" size={18} stroke={2.1} /></span>} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '8px 16px 40px' }}>
        <Card pad={16} radius={18}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <AvatarInitials nome={cliente.nome} size={56} />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span style={{ font: `600 18px ${T.font}`, color: T.navy }}>{cliente.nome}</span>
              <span style={{ font: `400 12px ${T.font}`, color: T.muted }}>P.IVA {cliente.piva}</span>
            </div>
          </div>
          <div style={{ height: 1, background: T.hair, margin: '12px 0 3px' }} />
          {contactRow('phone', cliente.tel)}
          <div style={{ height: 1, background: T.hair }} />
          {contactRow('mail', cliente.email)}
          <div style={{ height: 1, background: T.hair }} />
          {contactRow('pin', cliente.indirizzo)}
        </Card>
        {liste}
      </div>
    </ScreenScroll>
  );
}

// ── 6.3 Listino materiali / prezzi ───────────────────────────────────────
function Listino({ listino, go, variant = 'A', select = false }) {
  const [sel, setSel] = useState({});
  const [cat, setCat] = useState('Tutte');
  const [sheet, setSheet] = useState(false);
  const eur = n => '€ ' + n.toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const nSel = Object.values(sel).filter(Boolean).length;
  const cats = ['Tutte', ...listino.map(g => g.categoria)];
  const groups = variant === 'B' && cat !== 'Tutte' ? listino.filter(g => g.categoria === cat) : listino;
  const voceRow = (v, last) => (
    <div key={v.desc}>
      <div onClick={select ? () => setSel(s => ({ ...s, [v.desc]: !s[v.desc] })) : undefined}
        style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 0', cursor: select ? 'pointer' : 'default' }}>
        {select && (
          <span style={{
            width: 22, height: 22, borderRadius: 7, flex: 'none',
            border: sel[v.desc] ? 'none' : `1.5px solid ${T.hair2}`,
            background: sel[v.desc] ? T.navy : T.white,
            display: 'flex', alignItems: 'center', justifyContent: 'center', color: T.yellow,
          }}>{sel[v.desc] && <Icon name="check" size={13} stroke={3} />}</span>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0, flex: 1 }}>
          <span style={{ font: `500 14px ${T.font}`, color: T.navy }}>{v.desc}</span>
          <span style={{ font: `500 11px ${T.mono}`, color: T.muted }}>{v.unita}</span>
        </div>
        <span style={{ font: `600 14px ${T.mono}`, color: T.navy, flex: 'none' }}>{eur(v.p)}</span>
        {!select && <span style={{ color: T.muted, display: 'inline-flex' }}><Icon name="chevron" size={14} stroke={2.2} /></span>}
      </div>
      {!last && <div style={{ height: 1, background: T.hair }} />}
    </div>
  );
  return (
    <ScreenScroll tabbed={!select}>
      {select ? (
        <NavBar title="Aggiungi dal listino" onBack={() => go({ id: '5.2' })} />
      ) : (
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', padding: '58px 16px 8px' }}>
          <h1 style={{ margin: 0, font: `700 34px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Listino</h1>
          <button onClick={() => setSheet(true)} style={{ border: 'none', background: 'none', cursor: 'pointer', padding: 6, color: T.navy }}>
            <Icon name="plus" size={24} stroke={2.4} />
          </button>
        </div>
      )}
      {variant === 'B' && (
        <div style={{ display: 'flex', gap: 8, overflowX: 'auto', padding: '6px 16px 12px' }}>
          {cats.map(c => (
            <button key={c} onClick={() => setCat(c)} style={{
              padding: '7px 14px', borderRadius: 999, border: c === cat ? 'none' : `1px solid ${T.hair2}`,
              background: c === cat ? T.navy : T.white, color: c === cat ? T.yellow : T.navy,
              font: `600 12px ${T.font}`, cursor: 'pointer', whiteSpace: 'nowrap', flex: 'none',
            }}>{c}</button>
          ))}
        </div>
      )}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14, padding: `${variant === 'B' ? 0 : 8}px 16px ${select ? 120 : 40}px` }}>
        {groups.map(g => (
          <div key={g.categoria} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {variant !== 'B' && <span style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted, padding: '4px 2px 0' }}>{g.categoria}</span>}
            <Card pad={14}>{g.voci.map((v, i) => voceRow(v, i === g.voci.length - 1))}</Card>
          </div>
        ))}
        {!select && <span style={{ font: `400 12px ${T.font}`, color: T.muted, textAlign: 'center' }}>Scorri una voce verso sinistra per modificarla o eliminarla</span>}
      </div>
      {select && (
        <div style={{ position: 'absolute', left: 16, right: 16, bottom: 34, zIndex: 30 }}>
          <BrandButton title={nSel > 0 ? `Inserisci ${nSel} voc${nSel === 1 ? 'e' : 'i'} nel preventivo` : 'Seleziona le voci'} icon="check" disabled={nSel === 0} onClick={() => go({ id: '5.2' })} style={{ boxShadow: '0 12px 30px rgba(15,30,72,0.25)' }} />
        </div>
      )}
      {sheet && (
        <Sheet title="Nuova voce" onClose={() => setSheet(false)} cta="Salva voce" onCta={() => setSheet(false)}>
          <Field label="Descrizione" placeholder="Es. Rasatura armata" />
          <div style={{ display: 'flex', gap: 10 }}>
            <div style={{ flex: 1 }}><Field label="Unità" placeholder="m² / h / pz" /></div>
            <div style={{ flex: 1 }}><Field label="Prezzo unitario" icon="euro" placeholder="0,00" /></div>
          </div>
          <Field label="Categoria" icon="tag" placeholder="Es. Superfici" />
        </Sheet>
      )}
    </ScreenScroll>
  );
}

// ── 6.4 Impostazioni / Profilo ───────────────────────────────────────────
function Impostazioni({ go, variant = 'A' }) {
  const row = (icon, label, value, last, danger) => (
    <div key={label}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 0' }}>
        <div style={{ width: 34, height: 34, borderRadius: 10, background: danger ? 'rgba(217,52,43,0.10)' : T.grayBg, display: 'flex', alignItems: 'center', justifyContent: 'center', color: danger ? T.danger : T.navy }}>
          <Icon name={icon} size={16} stroke={2.1} />
        </div>
        <span style={{ font: `400 14px ${T.font}`, color: danger ? T.danger : T.navy }}>{label}</span>
        <span style={{ marginLeft: 'auto', font: `500 13px ${T.mono}`, color: T.muted }}>{value}</span>
        <span style={{ color: T.muted, display: 'inline-flex' }}><Icon name="chevron" size={14} stroke={2.2} /></span>
      </div>
      {!last && <div style={{ height: 1, background: T.hair }} />}
    </div>
  );
  const sezione = (titolo, rows) => (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ font: `600 10px ${T.font}`, letterSpacing: '.5px', textTransform: 'uppercase', color: T.muted, padding: '4px 2px 0' }}>{titolo}</span>
      <Card pad={14}>{rows}</Card>
    </div>
  );
  const profiloA = (
    <Card pad={16} radius={18} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <AvatarInitials nome="Carlo Marchetti" size={56} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
        <span style={{ font: `600 18px ${T.font}`, color: T.navy }}>Carlo Marchetti</span>
        <span style={{ font: `400 13px ${T.font}`, color: T.muted }}>carlo@impresaedile.it</span>
        <StatoChip text="Operatore" tint={T.muted} />
      </div>
      <span style={{ marginLeft: 'auto', color: T.muted }}><Icon name="pencil" size={17} stroke={2.1} /></span>
    </Card>
  );
  const profiloB = (
    <div style={{ background: T.navy, borderRadius: '0 0 28px 28px', padding: '66px 16px 24px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
      <div style={{ width: 72, height: 72, borderRadius: 22, background: T.yellow, color: T.navy, display: 'flex', alignItems: 'center', justifyContent: 'center', font: `700 26px ${T.font}` }}>CM</div>
      <div style={{ font: `700 22px ${T.font}`, color: '#fff' }}>Carlo Marchetti</div>
      <div style={{ font: `400 13px ${T.font}`, color: 'rgba(255,255,255,0.55)' }}>carlo@impresaedile.it</div>
      <span style={{ font: `600 10px ${T.font}`, color: T.yellow, padding: '4px 10px', borderRadius: 999, background: 'rgba(245,220,15,0.14)' }}>Operatore</span>
    </div>
  );
  return (
    <ScreenScroll tabbed>
      {variant === 'B' ? profiloB : (
        <div style={{ padding: '58px 16px 8px' }}>
          <h1 style={{ margin: 0, font: `700 34px ${T.font}`, color: T.navy, letterSpacing: '-.01em' }}>Profilo</h1>
        </div>
      )}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '12px 16px 40px' }}>
        {variant !== 'B' && profiloA}
        {sezione('Preventivi', [
          row('euro', 'Tariffa oraria default', '€ 35/h'),
          row('doc', 'IVA default', '22%'),
          row('check', 'Validità default', '30 giorni'),
          row('tag', 'Prefisso numerazione', 'PRV', true),
        ])}
        {sezione('App', [
          row('cloud', 'Dati e sincronizzazione', 'OK'),
          row('info', 'Informazioni', ''),
          row('gear', 'Versione', '2.4.0', true),
        ])}
        <BrandButton title="Esci" icon="logout" kind="ghost" onClick={() => go({ id: '0.2' })} style={{ color: T.danger, borderColor: 'rgba(217,52,43,0.35)' }} />
      </div>
    </ScreenScroll>
  );
}

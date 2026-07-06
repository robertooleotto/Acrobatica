// Acrobatica Prototype — dati seed + shell di navigazione + frame/scaler
// Montato dal DC via <x-import component-from-global-scope="AcroPrototype">.

const SEED_CANTIERI = [
  { id: 'c1', nome: 'Condominio Garibaldi', cliente: 'Rossi Costruzioni S.r.l.', clienteId: 'cl1', indirizzo: 'Via Garibaldi 14, Milano',
    rilievi: [
      { id: 'r1', nome: 'Facciata Nord', stato: 'Elaborato', foto: 24, areaLorda: 491.4, areaNetta: 408.2,
        aperture: [{ tipo: 'finestra', area: 2.10 }, { tipo: 'finestra', area: 2.10 }, { tipo: 'porta', area: 4.20 }] },
      { id: 'r2', nome: 'Facciata Est', stato: 'In cattura', foto: 9, areaNetta: 0, aperture: [] },
    ] },
  { id: 'c2', nome: 'Villa Bianchi', cliente: 'Bianchi Andrea', clienteId: 'cl2', indirizzo: 'Via dei Tigli 3, Monza',
    rilievi: [
      { id: 'r3', nome: 'Facciata principale', stato: 'Completato', foto: 31, areaLorda: 212.6, areaNetta: 178.9,
        aperture: [{ tipo: 'finestra', area: 1.80 }, { tipo: 'finestra', area: 1.80 }] },
    ] },
  { id: 'c3', nome: 'Capannone Logistica Sud', cliente: 'MV Immobiliare', clienteId: 'cl3', indirizzo: 'Z.I. Lotto 7, Pavia', rilievi: [] },
];

const SEED_CLIENTI = [
  { id: 'cl1', nome: 'Rossi Costruzioni S.r.l.', citta: 'Milano', nCantieri: 1, tel: '+39 02 5551 2340', email: 'info@rossicostruzioni.it', indirizzo: 'Via Garibaldi 14, Milano', piva: 'IT03456780962' },
  { id: 'cl2', nome: 'Bianchi Andrea', citta: 'Monza', nCantieri: 1, tel: '+39 339 481 2276', email: 'a.bianchi@pec.it', indirizzo: 'Via dei Tigli 3, Monza', piva: '—' },
  { id: 'cl3', nome: 'MV Immobiliare', citta: 'Pavia', nCantieri: 1, tel: '+39 0382 41 220', email: 'amministrazione@mvimmobiliare.it', indirizzo: 'Z.I. Lotto 7, Pavia', piva: 'IT01998450187' },
  { id: 'cl4', nome: 'Condominio Via Verdi 8', citta: 'Milano', nCantieri: 0, tel: '+39 02 8724 5510', email: 'amm.verdi8@studiocasa.it', indirizzo: 'Via Verdi 8, Milano', piva: '—' },
];

const SEED_PREVENTIVI = [
  { numero: 'PRV-2026-0001', cliente: 'Rossi Costruzioni S.r.l.', clienteId: 'cl1', stato: 'Bozza', totale: 11416.27, ore: 16, tariffa: 35 },
  { numero: 'PRV-2026-0002', cliente: 'Bianchi Andrea', clienteId: 'cl2', stato: 'Inviato', totale: 4850.00, ore: 8, tariffa: 35 },
  { numero: 'PRV-2025-0114', cliente: 'MV Immobiliare', clienteId: 'cl3', stato: 'Accettato', totale: 18230.00, ore: 40, tariffa: 35 },
  { numero: 'PRV-2025-0108', cliente: 'Condominio Via Verdi 8', clienteId: 'cl4', stato: 'Rifiutato', totale: 7120.00, ore: 12, tariffa: 35 },
];

const SEED_VOCI = [
  { desc: 'Tinteggiatura facciata', q: 408.2, unita: 'm²', p: 18 },
  { desc: 'Ponteggio + montaggio', q: 1, unita: 'corpo', p: 1450 },
];

const SEED_LISTINO = [
  { categoria: 'Superfici', voci: [
    { desc: 'Tinteggiatura facciata', unita: 'm²', p: 18 },
    { desc: 'Rasatura armata', unita: 'm²', p: 24.5 },
    { desc: 'Idropulitura', unita: 'm²', p: 6.5 },
  ] },
  { categoria: 'Aperture e contorni', voci: [
    { desc: 'Trattamento contorni finestre', unita: 'pz', p: 45 },
    { desc: 'Sigillatura davanzali', unita: 'pz', p: 28 },
  ] },
  { categoria: 'Struttura e accesso', voci: [
    { desc: 'Ponteggio + montaggio', unita: 'corpo', p: 1450 },
    { desc: 'Linea vita (nolo)', unita: 'corpo', p: 380 },
  ] },
  { categoria: 'Manodopera', voci: [
    { desc: 'Operatore su fune', unita: 'h', p: 35 },
    { desc: 'Capo squadra', unita: 'h', p: 42 },
  ] },
];

// Which routes show the tab bar / are dark chrome
const TAB_ROUTES = { '0.3': 1, '1.1': 1, '1.2': 1, '5.1': 1, '6.1': 1, '6.4': 1 };

function AcroApp({ nav, variants, dataset, go }) {
  const vuoto = dataset === 'vuoto';
  const cantieri = vuoto ? [] : SEED_CANTIERI;
  const clienti = vuoto ? [] : SEED_CLIENTI;
  const preventivi = vuoto ? [] : SEED_PREVENTIVI;

  // fallback ai dati demo per le schermate di dettaglio
  const cantiere = SEED_CANTIERI.find(c => c.id === nav.cantiere) || SEED_CANTIERI[0];
  const rilievo = (cantiere.rilievi.find(r => r.id === nav.rilievo)) || cantiere.rilievi[0] || SEED_CANTIERI[0].rilievi[0];
  const cliente = SEED_CLIENTI.find(c => c.id === nav.cliente) || SEED_CLIENTI[0];
  const preventivo = SEED_PREVENTIVI.find(p => p.numero === nav.preventivo) || SEED_PREVENTIVI[0];

  const id = nav.id;
  let screen = null;
  if (id === '0.1') screen = <Splash go={go} variant={variants.splash} />;
  else if (id === '0.2') screen = <Login go={go} variant={variants.login} />;
  else if (id === '0.3') screen = <Home cantieri={cantieri} preventivi={preventivi} go={go} variant={variants.home} onNuovoCantiere={() => go({ id: '1.2' })} />;
  else if (id === '1.1' || id === '1.2') screen = <>
    <CantieriList cantieri={cantieri} go={go} onNew={() => go({ id: '1.2' })} />
    {id === '1.2' && <NuovoCantiereSheet onClose={() => go({ id: '1.1' })} onCrea={() => go({ id: '1.4', cantiere: 'c1' })} />}
  </>;
  else if (id === '1.4') screen = <DettaglioCantiere cantiere={cantiere} go={go} />;
  else if (id === '2.1') screen = <CatturaAR pad={nav.pad} initialShots={nav.shots || 0}
    onClose={() => go({ id: '1.4', cantiere: cantiere.id })}
    onStop={() => go({ id: '3.1', cantiere: cantiere.id, rilievo: rilievo.id, processing: true })} />;
  else if (id === '3.1') screen = <RisultatoPanorama rilievo={rilievo} processing={nav.processing} go={go} backTo={{ id: '1.4', cantiere: cantiere.id }} />;
  else if (id === '3.2') screen = <Editor3D go={go} pad={nav.pad} />;
  else if (id === '3.4') screen = <Rettifica go={go} />;
  else if (id === '3.5') screen = <MisuraScala go={go} />;
  else if (id === '4.1') screen = <Marcatura rilievo={rilievo} go={go} />;
  else if (id === '5.1') screen = <PreventiviList preventivi={preventivi} go={go} />;
  else if (id === '5.2') screen = <PreventivoEditor preventivo={preventivo} voci={SEED_VOCI} go={go} />;
  else if (id === '5.4') screen = <PDFPreventivo preventivo={preventivo} voci={SEED_VOCI} go={go} />;
  else if (id === '5.5') screen = <FirmaCliente preventivo={preventivo} go={go} />;
  else if (id === '6.1') screen = <ClientiList clienti={clienti} go={go} variant={variants.clienti} />;
  else if (id === '6.2') screen = <ClienteDettaglio cliente={cliente} cantieri={cantieri} preventivi={preventivi} go={go} variant={variants.cliente} />;
  else if (id === '6.3') screen = <Listino listino={SEED_LISTINO} go={go} variant={variants.listino} select={nav.select} />;
  else if (id === '6.4') screen = <Impostazioni go={go} variant={variants.impostazioni} />;

  return <>
    {screen}
    {TAB_ROUTES[id] && id !== '1.2' && <TabBar active={id} go={go} />}
    {id === '1.2' && <TabBar active="1.1" go={go} />}
  </>;
}

function isDark(nav, variants) {
  const id = nav.id;
  if (id === '2.1' || id === '3.2') return true;
  if (id === '0.1' && variants.splash !== 'B') return true;
  if (id === '0.2' && variants.login === 'B') return true;
  return false;
}

// ── Root: frame (iPhone/iPad) + fit-to-stage scaling (sync, props-driven) ─
function AcroPrototype(props) {
  const nav = props.nav || { id: '0.3' };
  const variants = props.variants || {};
  const go = props.go || (() => {});
  const pad = !!nav.pad;
  const DW = pad ? 1194 : 402, DH = pad ? 834 : 874;

  // scale computed synchronously from stage dimensions passed by the DC host
  const stageW = props.stageW || (typeof window !== 'undefined' ? window.innerWidth - 252 : 800);
  const stageH = props.stageH || (typeof window !== 'undefined' ? window.innerHeight : 600);
  const scale = Math.max(0.1, Math.min((stageW - 48) / DW, (stageH - 48) / DH, 1));

  const dark = isDark(nav, variants);
  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
      <div style={{ width: DW * scale, height: DH * scale, flex: 'none' }}>
        <div style={{ transform: `scale(${scale})`, transformOrigin: 'top left' }}>
          {pad
            ? <TabletFrame dark={dark}><AcroApp nav={nav} variants={variants} dataset={props.dataset} go={go} /></TabletFrame>
            : <IOSDevice dark={dark}><AcroApp nav={nav} variants={variants} dataset={props.dataset} go={go} /></IOSDevice>}
        </div>
      </div>
    </div>
  );
}

window.AcroPrototype = AcroPrototype;

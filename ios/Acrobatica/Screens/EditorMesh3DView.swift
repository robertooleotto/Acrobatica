import SwiftUI
import SceneKit
import simd

/// Editor 3D della mesh di facciata (Object Capture).
///
/// FASE 1 (fondamenta): visore SceneKit con orbit/pan/zoom e auto-inquadratura
/// sul bounding box. Carica una mesh OBJ/USDZ da file locale, oppure una mesh
/// demo procedurale (muro + balcone sporgente + triangoli sparsi) per provare
/// al simulatore senza la mesh vera.
///
/// FASI SUCCESSIVE (vedi HANDOFF_editor_3d_ios.md): selezione regioni → taglio
/// distruttivo dei triangoli → denoise → estrazione piani per la proiezione.
struct EditorMesh3DView: View {
    @StateObject private var model: Mesh3DModel
    private let onChiudi: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var urlsExport: [URL] = []

    /// `meshFile` nil → mesh demo procedurale.
    init(meshFile: URL? = nil,
         nome: String = "Mesh facciata",
         onChiudi: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: Mesh3DModel(meshFile: meshFile, nome: nome))
        self.onChiudi = onChiudi
    }

    var body: some View {
        VStack(spacing: 0) {
            barraSuperiore
            ZStack(alignment: .topTrailing) {
                SceneKitContainer(model: model)
                if model.modoPerimetro && model.perimetroTraccia { PannelloPerimetro(model: model) }
                hud
                NavGizmo(model: model).padding(.top, 8).padding(.trailing, 10)
                railDestro
            }
            barraStrumenti
        }
        .background(EditorTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(
            get: { !urlsExport.isEmpty },
            set: { if !$0 { urlsExport = [] } }
        )) {
            CondivisioneMesh(elementi: urlsExport)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    private var barraSuperiore: some View {
        HStack(spacing: 14) {
            Button {
                if let onChiudi { onChiudi() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EditorTheme.testo)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.nome)
                    .font(Theme.Typo.title(15))
                    .foregroundStyle(EditorTheme.testo)
                Text("Editor 3D · pulizia mesh")
                    .font(Theme.Typo.caption(10))
                    .foregroundStyle(EditorTheme.testoMuto)
            }
            Spacer()
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 36)
            }
            .disabled(!model.puoUndo)
            .foregroundStyle(model.puoUndo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))
            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 36)
            }
            .disabled(!model.puoRedo)
            .foregroundStyle(model.puoRedo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))
            Button {
                let nome = model.nome.replacingOccurrences(of: " ", with: "_")
                urlsExport = model.esportaProxy(nomeBase: nome)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(model.facce.isEmpty ? EditorTheme.testoMuto.opacity(0.4) : EditorTheme.testo)
            }
            .disabled(model.facce.isEmpty)
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EditorTheme.panel)
        .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .bottom)
    }

    /// Menu delle viste (proxy/piani/geometria/texture/validazione) — nel rail.
    private var vistaMenu: some View {
        Menu {
            Button { model.mostraProxy.toggle() } label: {
                Label("Proxy colorati", systemImage: model.mostraProxy ? "checkmark" : "circle")
            }
            Button { model.mostraPiani.toggle() } label: {
                Label("Piani fittati", systemImage: model.mostraPiani ? "checkmark" : "circle")
            }
            Divider()
            Button { model.mostraMesh.toggle() } label: {
                Label("Geometria OC", systemImage: model.mostraMesh ? "checkmark" : "circle")
            }
            if model.haTexturaOC {
                Button { model.mostraTexturaOC.toggle() } label: {
                    Label("Texture OC", systemImage: model.mostraTexturaOC ? "checkmark" : "circle")
                }
            }
            Divider()
            ForEach(VistaValidazione.allCases) { v in
                Button { model.vistaValidazione = v } label: {
                    Label(v.etichetta, systemImage: model.vistaValidazione == v ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(EditorTheme.testo)
                .frame(width: 38, height: 38)
        }
    }

    /// Rail verticale a destra: strumenti + viste + reset (sostituisce la fila in basso).
    private var railDestro: some View {
        HStack {
            Spacer()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    ForEach(StrumentoMesh3D.allCases.filter { $0 != .punti && $0 != .seleziona }) { s in
                        Button {
                            model.annullaFaccia(); model.strumento = s
                        } label: {
                            Image(systemName: s.icona)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(model.strumento == s ? .white : EditorTheme.testo)
                                .frame(width: 38, height: 38)
                                .background(model.strumento == s ? EditorTheme.accento : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    railDivisore
                    vistaMenu
                    Button { model.inquadra() } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(EditorTheme.testo)
                            .frame(width: 38, height: 38)
                    }
                    railDivisore
                    Button { model.ricaricaDaCapo() } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 38, height: 38)
                    }
                    .disabled(model.caricamento || model.numTriangoli == 0)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 5)
                .background(EditorTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(EditorTheme.hair, lineWidth: 1))
                Spacer()
            }
            .padding(.trailing, 10)
        }
    }

    private var railDivisore: some View {
        Rectangle().fill(EditorTheme.hair).frame(width: 22, height: 1).padding(.vertical, 2)
    }

    private var hud: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let err = model.errore {
                        Text(err)
                            .font(Theme.Typo.caption(11))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Label("\(model.numVertici) vertici", systemImage: "circle.grid.3x3")
                        Label("\(model.numTriangoli) triangoli", systemImage: "triangle")
                        if !model.facce.isEmpty {
                            Label("\(model.facce.count) facce", systemImage: "paintbrush")
                                .foregroundStyle(EditorTheme.accento)
                        }
                        if let info = model.cursoreInfo {
                            Label(info, systemImage: "scope")
                                .foregroundStyle(EditorTheme.accento)
                        }
                    }
                }
                .font(Theme.Typo.mono(10))
                .foregroundStyle(EditorTheme.testo)
                .padding(8)
                .background(EditorTheme.panel.opacity(0.88),
                            in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            Spacer()
            if model.caricamento {
                ProgressView().tint(EditorTheme.accento)
                    .padding(10)
                    .background(EditorTheme.panel.opacity(0.9), in: Circle())
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    // MARK: – Barra strumenti (Fase 2: creazione faccia per punti)

    /// Barra inferiore = SOLO contesto dello strumento attivo (gli strumenti sono
    /// nel rail a destra). In Naviga non c'è barra: massimo spazio al modello.
    @ViewBuilder private var barraStrumenti: some View {
        if model.modoPerimetro {
            barraPerimetro
                .padding(.vertical, 8)
                .background(EditorTheme.panel)
                .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
        } else if model.strumento != .orbita {
            VStack(spacing: 8) {
                if model.strumento == .box { barraBox }
                if model.strumento == .facce { barraPiani }
            }
            .padding(.vertical, 8)
            .background(EditorTheme.panel)
            .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
        }
    }

    private var barraPerimetro: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").font(.system(size: 13))
                    .foregroundStyle(EditorTheme.accento)
                Text(model.perimetroTraccia ? "Quota" : "Posiziona la sezione")
                    .font(Theme.Typo.caption(11)).foregroundStyle(EditorTheme.testoMuto)
                Slider(value: $model.quotaSlice, in: 0...1).tint(EditorTheme.accento)
                Text("\(Int(model.quotaSlice * 100))%").font(Theme.Typo.mono(10))
                    .foregroundStyle(EditorTheme.testoMuto).frame(width: 36, alignment: .trailing)
            }
            if !model.perimetroTraccia {
                // FASE 1: posiziona la sezione sul 3D, poi passa a tracciare
                HStack(spacing: 8) {
                    Text("sposta lo slice; ruota la vista se vuoi")
                        .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.testoMuto)
                    Spacer()
                    Button { model.iniziaTraccia() } label: {
                        Label("Traccia il bordo", systemImage: "scribble.variable")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(EditorTheme.accento, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    Button { model.esciPerimetro() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                }
            } else {
                // FASE 2: tracciamento nel pannello 2D
                HStack(spacing: 8) {
                    Button { model.perimetroTraccia = false } label: {
                        Label("Sposta sezione", systemImage: "arrow.up.and.down")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { model.chiudiPerimetro.toggle() } label: {
                        Label("Chiudi", systemImage: model.chiudiPerimetro ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.chiudiPerimetro ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.chiudiPerimetro ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { model.autoPerimetro() } label: {
                        Label("Auto angoli", systemImage: "wand.and.stars")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    Button { model.annullaUltimoPuntoPerimetro() } label: {
                        Label("Indietro", systemImage: "arrow.uturn.backward")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                    }
                    .disabled(model.numPuntiPerimetro == 0).opacity(model.numPuntiPerimetro == 0 ? 0.4 : 1)
                    Button { model.estrudiPerimetro() } label: {
                        Label("Estrudi (\(model.numPuntiPerimetro))", systemImage: "square.stack.3d.up.fill")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .disabled(model.numPuntiPerimetro < 2).opacity(model.numPuntiPerimetro < 2 ? 0.5 : 1)
                    Button { model.esciPerimetro() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var barraPiani: some View {
        VStack(spacing: 8) {
            // 1 · MODO — come marchi le superfici (pulsanti con etichetta) + Aggiungi
            HStack(spacing: 6) {
                ForEach(ModoSelezione.allCases) { m in
                    Button { model.modoSelezione = m } label: {
                        Label(m.etichetta, systemImage: m.icona)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.modoSelezione == m ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.modoSelezione == m ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Spacer()
                if model.modoSelezione.disegnaSelezione {
                    Button { model.selezioneAdditiva.toggle() } label: {
                        Label("Aggiungi", systemImage: model.selezioneAdditiva ? "plus.square.fill.on.square.fill" : "plus.square.on.square")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.selezioneAdditiva ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.selezioneAdditiva ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button { model.avviaPerimetro() } label: {
                    Label("Perimetro", systemImage: "scissors")
                        .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.numTriangoli == 0)
            }
            if model.modoSelezione == .pennello { controlliPennello }

            // 2 · GENERA — appare solo quando hai marcato qualcosa (semi o selezione)
            if model.numSemi > 0 || model.numSelezionati > 0 {
                HStack(spacing: 8) {
                    Button { model.generaDaMarcatura() } label: {
                        Label(model.numSemi > 0 ? "Genera piani (\(model.numSemi))" : "Genera piani",
                              systemImage: "square.stack.3d.up.fill")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    if model.facciaAttivaId != nil && model.numSelezionati > 0 {
                        ChipSelezione("Aggiungi a piano", "plus.rectangle.on.rectangle") {
                            model.aggiungiSelezioneAlPianoAttivo()
                        }
                    }
                    Button { model.annullaMarcatura() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                    Spacer()
                    if model.numSelezionati > 0 {
                        Text("\(model.numSelezionati) tri").font(Theme.Typo.mono(10))
                            .foregroundStyle(EditorTheme.testoMuto)
                    }
                }
                if model.modoSelezione.disegnaSelezione {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ChipSelezione("Tutto", "checklist") { model.selezionaTutto() }
                            ChipSelezione("Niente", "xmark.circle") { model.deselezionaTutto() }
                            ChipSelezione("Inverti", "arrow.2.squarepath") { model.invertiSelezione() }
                            ChipSelezione("Frammenti", "sparkles") { model.selezionaFrammenti() }
                            ChipSelezione("Espandi", "plus.magnifyingglass") { model.espandiSelezione() }
                            ChipSelezione("Restringi", "minus.magnifyingglass") { model.restringiSelezione() }
                            ChipSelezione("Elimina mesh", "trash") { model.eliminaSelezione() }
                        }
                    }
                }
            } else {
                Text(suggerimentoPiani)
                    .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.testoMuto)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 3 · PIANO ATTIVO — modifica del piano selezionato
            if let fa = model.facciaAttiva {
                HStack(spacing: 8) {
                    Circle().fill(Color(uiColor: fa.colore)).frame(width: 12, height: 12)
                    TextField("Nome faccia", text: Binding(
                        get: { model.facciaAttiva?.nome ?? "" },
                        set: { if let id = model.facciaAttivaId { model.rinominaFaccia(id, $0) } }))
                        .font(Theme.Typo.body(13, .semibold))
                        .foregroundStyle(EditorTheme.testo)
                        .textFieldStyle(.plain)
                    Menu {
                        ForEach(TipoFaccia.allCases) { t in
                            Button(t.etichetta) { model.cambiaTipoFaccia(fa.id, t) }
                        }
                    } label: {
                        Text(fa.tipo.etichetta)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(EditorTheme.accento)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(EditorTheme.accento.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }
                    // Priorità layer (§5): chi sta davanti nel bake.
                    HStack(spacing: 2) {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 10))
                        Text("\(fa.priorita)").font(Theme.Typo.mono(11)).frame(minWidth: 14)
                        Stepper("", value: Binding(
                            get: { model.facciaAttiva?.priorita ?? 0 },
                            set: { model.cambiaPrioritaFaccia(fa.id, $0) }), in: 0...20)
                            .labelsHidden().scaleEffect(0.7).frame(width: 64)
                    }
                    .foregroundStyle(EditorTheme.testoMuto)
                    if let e = fa.erroreRms {
                        Text(String(format: "±%.3f", e))
                            .font(Theme.Typo.mono(10))
                            .foregroundStyle(e < model.sogliaErrore ? EditorTheme.testoMuto : Theme.danger)
                    }
                    if let a = model.areaPoligono(fa) {
                        Text(String(format: "%.2f u²", a))
                            .font(Theme.Typo.mono(10))
                            .foregroundStyle(EditorTheme.accento)
                    }
                    if model.facce.count > 1 {
                        Menu {
                            ForEach(model.facce.filter { $0.id != fa.id }) { altra in
                                Button("Unisci \(altra.nome)") {
                                    model.unisciFacce(target: fa.id, sorgente: altra.id)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.merge")
                                .foregroundStyle(EditorTheme.testo).frame(width: 28, height: 28)
                        }
                    }
                    Button { model.eliminaFaccia(fa.id) } label: {
                        Image(systemName: "trash").foregroundStyle(Theme.danger).frame(width: 28, height: 28)
                    }
                }
                // Riconoscimento dal pennello: espandi al muro + punto zero.
                HStack(spacing: 6) {
                    ChipSelezione("Espandi al piano", "arrow.up.backward.and.arrow.down.forward") {
                        model.espandiAlPiano()
                    }
                    Button { model.attivaPuntoZero() } label: {
                        Label("Punto zero", systemImage: "scope")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.attendePuntoZero ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(model.attendePuntoZero ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.attendePuntoZero {
                        Text("tocca il muro vero")
                            .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.accento)
                    }
                    Spacer()
                }
                // Rifinitura piano (§6): squadra/verticale/orizzontale/offset.
                if fa.pianoNormale != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ChipSelezione("Squadra", "square.dashed") { model.squadraPiano(fa.id) }
                            ChipSelezione("Verticale", "arrow.up.and.down") { model.pianoVerticale(fa.id) }
                            ChipSelezione("Orizzontale", "arrow.left.and.right") { model.pianoOrizzontale(fa.id) }
                            ChipSelezione("Offset −", "minus") { model.offsetPiano(fa.id, verso: -1) }
                            ChipSelezione("Offset +", "plus") { model.offsetPiano(fa.id, verso: 1) }
                            ChipSelezione("Allinea facciata", "link") { model.allineaAllaFacciata(fa.id) }
                            ChipSelezione("Fitta mesh", "scope") { model.fittaPianoAllaMesh(fa.id) }
                            Divider().frame(height: 16)
                            ChipSelezione("Cima +", "arrow.up.to.line") { model.regolaAltezzaFaccia(fa.id, cima: true, verso: 1) }
                            ChipSelezione("Cima −", "arrow.down.to.line") { model.regolaAltezzaFaccia(fa.id, cima: true, verso: -1) }
                            ChipSelezione("Base +", "arrow.up") { model.regolaAltezzaFaccia(fa.id, cima: false, verso: 1) }
                            ChipSelezione("Base −", "arrow.down") { model.regolaAltezzaFaccia(fa.id, cima: false, verso: -1) }
                        }
                    }
                }
            }
            // 4 · PASTIGLIE dei piani — tocca per renderne uno attivo
            if !model.facce.isEmpty {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.facce) { f in
                                Button { model.selezionaFacciaAttiva(f.id) } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(Color(uiColor: f.colore)).frame(width: 9, height: 9)
                                        Text("\(f.nome) · \(f.triangoli.count)")
                                            .font(Theme.Typo.caption(10, .semibold))
                                            .foregroundStyle(EditorTheme.testo)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(f.id == model.facciaAttivaId ? EditorTheme.accento.opacity(0.25) : EditorTheme.panelAlt,
                                                in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    Menu {
                        ForEach(StatoProxy.allCases) { s in
                            Button(s.etichetta) { model.statoProxy = s }
                        }
                    } label: {
                        Text(model.statoProxy.etichetta)
                            .font(Theme.Typo.caption(10, .semibold))
                            .foregroundStyle(EditorTheme.testoMuto)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var suggerimentoPiani: String {
        switch model.modoSelezione {
        case .seleziona:  return "tocca un piano per selezionarlo e modificarlo"
        case .tocco:      return "tocca ogni superficie per un seme, poi Genera piani"
        case .pennello:   return "pennella le superfici, poi Genera piani"
        case .rettangolo: return "trascina un rettangolo sulle superfici, poi Genera piani"
        case .lazo:       return "circonda le superfici col lazo, poi Genera piani"
        }
    }

    private var barraBox: some View {
        HStack(spacing: 8) {
            Text("Trascina le maniglie, poi ritaglia")
                .font(Theme.Typo.caption(11))
                .foregroundStyle(EditorTheme.testoMuto)
            Spacer()
            ChipSelezione("Allinea", "cube.transparent") { model.allineaBox() }
            ChipSelezione("Reset", "arrow.counterclockwise") { model.resetBox() }
            ChipSelezione("Inverti", "rectangle.righthalf.inset.filled") { model.applicaCrop(inverti: true) }
            Button { model.applicaCrop(inverti: false) } label: {
                Label("Ritaglia", systemImage: "crop")
                    .font(Theme.Typo.caption(12, .bold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(EditorTheme.accento, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
    }


    /// Controlli del pennello: dimensione + vincolo alle normali con tolleranza.
    private var controlliPennello: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").font(.system(size: 12))
                    .foregroundStyle(EditorTheme.testoMuto)
                Slider(value: Binding(get: { Double(model.raggioPennello) },
                                      set: { model.raggioPennello = CGFloat($0) }), in: 12...110)
                    .tint(EditorTheme.accento)
                Text("\(Int(model.raggioPennello)) px").font(Theme.Typo.mono(10))
                    .foregroundStyle(EditorTheme.testoMuto).frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button { model.vincolaNormali.toggle() } label: {
                    Label("Vincola normali", systemImage: model.vincolaNormali ? "checkmark.square.fill" : "square")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.vincolaNormali ? EditorTheme.accento : EditorTheme.testo)
                }
                if model.vincolaNormali {
                    Slider(value: $model.tolleranzaNormaleGradi, in: 5...80).tint(EditorTheme.accento)
                    Text("±\(Int(model.tolleranzaNormaleGradi))°").font(Theme.Typo.mono(10))
                        .foregroundStyle(EditorTheme.testoMuto).frame(width: 40, alignment: .trailing)
                } else {
                    Spacer()
                }
            }
        }
    }

    private var suggerimentoPunti: String {
        switch model.numPuntiFaccia {
        case 0:  return "Tocca 3+ punti sul muro a livello zero"
        case 1, 2: return "\(model.numPuntiFaccia) punti · servono ≥3"
        default: return "\(model.numPuntiFaccia) punti · calcola il piano"
        }
    }
}

// MARK: – ViewCube di navigazione (alto-destra, stile 3ds Max)

private struct NavGizmo: View {
    @ObservedObject var model: Mesh3DModel
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(EditorTheme.accento.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                    .frame(width: 84, height: 84)
                ViewCubeMini(model: model).frame(width: 58, height: 58)
            }
            HStack(spacing: 6) {
                Button { model.toggleAutoRuota() } label: {
                    Image(systemName: model.autoRuota ? "pause.fill" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 26)
                        .background(model.autoRuota ? EditorTheme.accento : EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(model.autoRuota ? .white : EditorTheme.testo)
                }
                gizBtn("F") { model.snapFronte() }
                gizBtn("A") { model.snapAlto() }
                gizBtn("◳") { model.snapIso() }
            }
        }
        .padding(6)
        .background(EditorTheme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
    private func gizBtn(_ t: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(t).font(Theme.Typo.caption(12, .bold))
                .frame(width: 28, height: 26)
                .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(EditorTheme.testo)
        }
    }
}

/// Cubetto 3D che rispecchia l'orientamento della camera; tap su una faccia →
/// snap a quella vista.
private struct ViewCubeMini: UIViewRepresentable {
    @ObservedObject var model: Mesh3DModel
    func makeCoordinator() -> Coord { Coord(model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.scene = SCNScene()
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.08)
        box.materials = Self.facce()
        let cube = SCNNode(geometry: box); cube.name = "cube"
        v.scene!.rootNode.addChildNode(cube)

        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera!.usesOrthographicProjection = true
        cam.camera!.orthographicScale = 0.95
        cam.position = SCNVector3(0, 0, 4)
        v.scene!.rootNode.addChildNode(cam); v.pointOfView = cam
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 600
        v.scene!.rootNode.addChildNode(amb)
        let dir = SCNNode(); dir.light = SCNLight(); dir.light!.type = .directional
        dir.eulerAngles = SCNVector3(-0.6, 0.5, 0); v.scene!.rootNode.addChildNode(dir)

        context.coordinator.cube = cube; context.coordinator.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        // Il cubo mostra come è orientata la scena dalla camera corrente.
        context.coordinator.cube?.simdOrientation = model.cameraQuat.inverse
    }

    /// 6 facce etichettate (ordine SCNBox: +Z,+X,-Z,-X,+Y,-Y).
    static func facce() -> [SCNMaterial] {
        let rosso = UIColor(red: 0.86, green: 0.30, blue: 0.27, alpha: 1)
        let verde = UIColor(red: 0.30, green: 0.66, blue: 0.38, alpha: 1)
        let blu   = UIColor(red: 0.27, green: 0.55, blue: 0.84, alpha: 1)
        return [("F", blu), ("D", rosso), ("R", blu), ("S", rosso), ("A", verde), ("B", verde)]
            .map { etichetta($0.0, $0.1) }
    }
    private static func etichetta(_ s: String, _ bg: UIColor) -> SCNMaterial {
        let size = CGSize(width: 128, height: 128)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            bg.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 60, weight: .bold),
                .foregroundColor: UIColor.white, .paragraphStyle: p]
            (s as NSString).draw(in: CGRect(x: 0, y: 30, width: 128, height: 80), withAttributes: attr)
        }
        let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .blinn
        return m
    }

    final class Coord: NSObject {
        let model: Mesh3DModel
        weak var view: SCNView?
        weak var cube: SCNNode?
        init(_ model: Mesh3DModel) { self.model = model }

        @MainActor @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let hits = v.hitTest(g.location(in: v), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let h = hits.first else { return }
            let ln = h.localNormal   // normale locale del cubo ≈ ±asse
            let n = SIMD3<Float>(Float(ln.x), Float(ln.y), Float(ln.z))
            let ax = [abs(n.x), abs(n.y), abs(n.z)]
            let idx = ax[0] >= ax[1] && ax[0] >= ax[2] ? 0 : (ax[1] >= ax[2] ? 1 : 2)
            let segno: Float = [n.x, n.y, n.z][idx] >= 0 ? 1 : -1
            model.snapAsse(idx, segno)
        }
    }
}

/// Share sheet per i JSON proxy esportati.
private struct CondivisioneMesh: UIViewControllerRepresentable {
    let elementi: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: elementi, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Chip d'azione per le operazioni di selezione.
private struct ChipSelezione: View {
    let titolo: String
    let icona: String
    let azione: () -> Void
    init(_ titolo: String, _ icona: String, _ azione: @escaping () -> Void) {
        self.titolo = titolo; self.icona = icona; self.azione = azione
    }
    var body: some View {
        Button(action: azione) {
            Label(titolo, systemImage: icona)
                .font(Theme.Typo.caption(11, .semibold))
                .foregroundStyle(EditorTheme.testo)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Pulsante strumento 3D (zona pollice, 44pt), stile coerente con l'editor 2D.
private struct PulsanteStrumento3D: View {
    let strumento: StrumentoMesh3D
    let attivo: Bool
    let azione: () -> Void

    var body: some View {
        Button(action: azione) {
            VStack(spacing: 2) {
                Image(systemName: strumento.icona)
                    .font(.system(size: 16, weight: .medium))
                Text(strumento.etichetta)
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(attivo ? .white : EditorTheme.testo)
            .frame(width: 60, height: 44)
            .background(attivo ? EditorTheme.accento : EditorTheme.panelAlt,
                        in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

// MARK: – Container SceneKit (UIKit)

/// Wrapper di `SCNView` con orbit/pan/zoom integrati (defaultCameraController).
/// L'inquadratura usa `frameNodes(_:)` del camera controller — più affidabile
/// di una camera piazzata a mano sotto `allowsCameraControl`.
private struct SceneKitContainer: UIViewRepresentable {
    @ObservedObject var model: Mesh3DModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = model.scene
        v.allowsCameraControl = true          // orbit / pan / pinch-zoom (il tap resta libero)
        v.autoenablesDefaultLighting = false  // solo le nostre luci (directional+ambient)
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.backgroundColor = UIColor(EditorTheme.bg)
        v.antialiasingMode = .multisampling4X
        context.coordinator.view = v

        // Tap = aggiunge un punto della faccia (solo in modalità .punti).
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        v.addGestureRecognizer(tap)

        // Pan = lazo di selezione (abilitato solo in modalità .seleziona).
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        v.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let lasso = CAShapeLayer()
        lasso.fillColor = UIColor(EditorTheme.accento).withAlphaComponent(0.15).cgColor
        lasso.strokeColor = UIColor(EditorTheme.accento).cgColor
        lasso.lineWidth = 1.5
        lasso.lineDashPattern = [6, 4]
        v.layer.addSublayer(lasso)
        context.coordinator.lassoLayer = lasso
        v.delegate = context.coordinator   // per leggere l'orientamento camera (ViewCube)
        // Snap vista: callback diretto (affidabile anche a scena ferma).
        let node = model.contentNode
        model.richiediSnap = { [weak v] dir, up in
            guard let v = v else { return }
            Self.orientaCamera(v, contentNode: node, dir: dir, up: up)
        }
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        // In .seleziona/.box/.facce il pan è nostro: spegni la camera.
        let panNostro = model.strumento == .seleziona || model.strumento == .box
            || model.strumento == .facce
        v.allowsCameraControl = !panNostro
        context.coordinator.pan?.isEnabled = panNostro

        if context.coordinator.lastTick != model.reframeTick {
            context.coordinator.lastTick = model.reframeTick
            let node = model.contentNode
            DispatchQueue.main.async { v.defaultCameraController.frameNodes([node]) }
        }
    }

    /// Orienta la camera lungo `dir` inquadrando la mesh (chiamato dallo snap).
    static func orientaCamera(_ v: SCNView, contentNode: SCNNode,
                              dir: SIMD3<Float>, up: SIMD3<Float>) {
        let bb = contentNode.flattenedClone().boundingBox
        let center = SIMD3<Float>((bb.min.x + bb.max.x) / 2, (bb.min.y + bb.max.y) / 2, (bb.min.z + bb.max.z) / 2)
        let diag = simd_length(SIMD3<Float>(bb.max.x - bb.min.x, bb.max.y - bb.min.y, bb.max.z - bb.min.z))
        let fovDeg = v.pointOfView?.camera?.fieldOfView ?? 55
        let fov = Float(fovDeg * .pi / 180)
        let dist = (diag * 0.5) / tan(fov * 0.5) * 1.25
        let eye = center + dir * dist
        let m = lookAt(eye: eye, center: center, up: up)

        // Nuovo nodo camera: il defaultCameraController lo adotta col target,
        // così lo snap regge (impostare il transform del pov esistente viene
        // sovrascritto dal controller).
        let cam = SCNCamera()
        cam.fieldOfView = fovDeg
        cam.zNear = 0.01
        cam.zFar = Double(dist + diag) * 4
        v.scene?.rootNode.childNode(withName: "snapCam", recursively: false)?.removeFromParentNode()
        let nodo = SCNNode(); nodo.name = "snapCam"; nodo.camera = cam; nodo.simdTransform = m
        v.scene?.rootNode.addChildNode(nodo)
        v.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
        v.pointOfView = nodo
    }

    /// Matrice di vista (camera SceneKit guarda lungo -Z).
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        var s = simd_cross(f, up)
        if simd_length(s) < 1e-5 { s = simd_cross(f, SIMD3<Float>(1, 0, 0)) }
        s = simd_normalize(s)
        let u = simd_cross(s, f)
        let zc = -f
        return simd_float4x4(
            SIMD4<Float>(s.x, s.y, s.z, 0),
            SIMD4<Float>(u.x, u.y, u.z, 0),
            SIMD4<Float>(zc.x, zc.y, zc.z, 0),
            SIMD4<Float>(eye.x, eye.y, eye.z, 1))
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let model: Mesh3DModel
        weak var view: SCNView?
        weak var pan: UIPanGestureRecognizer?
        var lassoLayer: CAShapeLayer?
        var lastTick = -1
        var lastSnap = 0
        private var lassoPunti: [CGPoint] = []
        private var ultimoQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        // Fase C: maniglia del poligono in trascinamento.
        private struct Trascina {
            let faccia: Int; let edge: Bool; let k: Int
            let p: SIMD3<Float>; let n: SIMD3<Float>
            let start: SIMD3<Float>; let orig: [SIMD3<Float>]
        }
        private var trascina: Trascina?

        init(_ model: Mesh3DModel) { self.model = model }

        /// Intersezione del raggio dello schermo `sp` col piano (p,n). Per il drag.
        @MainActor private func puntoSulPiano(_ sp: CGPoint, p: SIMD3<Float>, n: SIMD3<Float>, in v: SCNView) -> SIMD3<Float>? {
            let a = v.unprojectPoint(SCNVector3(Float(sp.x), Float(sp.y), 0))
            let b = v.unprojectPoint(SCNVector3(Float(sp.x), Float(sp.y), 1))
            let o = SIMD3<Float>(a.x, a.y, a.z)
            let d = SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)
            let den = simd_dot(d, n)
            if abs(den) < 1e-6 { return nil }
            let t = simd_dot(p - o, n) / den
            return t >= 0 ? o + d * t : nil
        }

        /// Maniglia (angolo "maniglia:f:k" o edge "edge:f:k") sotto `sp`, se c'è.
        @MainActor private func maniglia(sotto sp: CGPoint, in v: SCNView) -> (faccia: Int, edge: Bool, k: Int)? {
            let hits = v.hitTest(sp, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for h in hits {
                guard let nm = h.node.name else { continue }
                let parti = nm.split(separator: ":")
                guard parti.count == 3, let fid = Int(parti[1]), let k = Int(parti[2]) else { continue }
                if parti[0] == "maniglia" { return (fid, false, k) }
                if parti[0] == "edge" { return (fid, true, k) }
            }
            return nil
        }

        // Mirror dell'orientamento camera → ViewCube (throttle se cambia poco).
        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pov = renderer.pointOfView else { return }
            let q = pov.simdOrientation
            Task { @MainActor in self.aggiornaQuat(q) }
        }

        @MainActor private func aggiornaQuat(_ q: simd_quatf) {
            let d = abs(simd_dot(q.vector, ultimoQuat.vector))
            if d < 0.9999 {   // ~ aggiorna solo se l'orientamento è cambiato
                ultimoQuat = q
                model.cameraQuat = q
            }
        }

        @MainActor @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let pt = g.location(in: v)
            // Rileva perimetro: il tracciamento avviene nel pannello 2D; sul 3D il
            // tap non fa nulla (si posiziona la sezione con lo slider, si ruota col pan).
            if model.modoPerimetro { return }
            // Naviga: il tap posa il mirino d'ispezione sulla mesh.
            if model.strumento == .orbita {
                let hits = v.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
                if let h = hits.first(where: { $0.node === model.contentNode }) {
                    model.posizionaCursore(h.worldCoordinates, triangolo: h.faceIndex)
                }
                return
            }
            // Facce + attesa punto zero: il tap fissa il punto zero sul muro.
            if model.strumento == .facce && model.attendePuntoZero {
                let hits = v.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
                if let h = hits.first(where: { $0.node === model.contentNode }) {
                    model.impostaPuntoZero(h.worldCoordinates)
                }
                return
            }
            // Piani: maniglia edge → splitta; piano esistente → selezionalo;
            // altrimenti, in modo "tocco", lascia un seme (cresce dopo con Genera).
            if model.strumento == .facce {
                if let m = maniglia(sotto: pt, in: v), m.edge {
                    model.splittaEdge(faccia: m.faccia, edge: m.k)
                    return
                }
                // Piano solo-poligono (es. facciata estrusa): selezionabile dal suo
                // riempimento "piano:<id>".
                let tutti = v.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
                for hh in tutti {
                    if let nm = hh.node.name, nm.hasPrefix("piano:"),
                       let id = Int(nm.dropFirst("piano:".count)) {
                        model.selezionaFacciaAttiva(id); return
                    }
                }
                let hits = v.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
                guard let h = hits.first(where: { $0.node === model.contentNode }) else { return }
                if let g = model.facce.first(where: { $0.triangoli.contains(h.faceIndex) }) {
                    model.selezionaFacciaAttiva(g.id)
                } else if model.modoSelezione == .tocco {
                    let w = h.worldCoordinates
                    model.aggiungiSeme(triangolo: h.faceIndex, punto: SIMD3<Float>(w.x, w.y, w.z))
                }
                return
            }
            guard model.strumento == .punti else { return }
            let hits = v.hitTest(pt, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
            ])
            for h in hits where discendente(h.node, di: model.contentNode) {
                model.aggiungiPunto(h.worldCoordinates)
                return
            }
        }

        // Proiezioni schermo dei baricentri, calcolate UNA volta a inizio gesto
        // (in selezione la camera è ferma → si riusano per tutto il gesto).
        private var cacheSchermo: [(i: Int, p: CGPoint)] = []
        private var rettInizio: CGPoint?
        private var refNormale: SIMD3<Float>?   // normale sotto il dito a inizio pennellata
        @MainActor private var raggioPennello: CGFloat { model.raggioPennello }

        /// Normale del triangolo colpito sotto `p` (riferimento del vincolo).
        @MainActor private func catturaNormaleRif(_ p: CGPoint, in v: SCNView) {
            let hits = v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let h = hits.first(where: { $0.node === model.contentNode }) {
                refNormale = model.mesh.normale(h.faceIndex)
            } else {
                refNormale = nil
            }
        }

        /// Il triangolo `i` passa il vincolo normali rispetto al riferimento?
        @MainActor private func passaNormale(_ i: Int) -> Bool {
            guard model.vincolaNormali, let ref = refNormale else { return true }
            let cosTol = Float(cos(model.tolleranzaNormaleGradi * .pi / 180))
            return abs(simd_dot(model.mesh.normale(i), ref)) >= cosTol
        }

        @MainActor @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            if model.strumento == .box { handlePanBox(g, in: v); return }
            if model.strumento == .facce { handlePanFacce(g, in: v); return }
            let p = g.location(in: v)
            switch g.state {
            case .began:
                proiettaCentroidi(in: v)
                catturaNormaleRif(p, in: v)
                rettInizio = p
                lassoPunti = [p]
                if model.modoSelezione == .pennello { model.applicaLazo([], aggiungi: false); pennella(p) }
            case .changed:
                switch model.modoSelezione {
                case .lazo:
                    lassoPunti.append(p); aggiornaTracciato(chiusa: true)
                case .rettangolo:
                    aggiornaRettangolo(da: rettInizio ?? p, a: p)
                case .pennello:
                    pennella(p); disegnaCerchioPennello(p)
                case .tocco, .seleziona:
                    break
                }
            case .ended, .cancelled:
                switch model.modoSelezione {
                case .lazo:
                    aggiornaTracciato(chiusa: true)
                    if lassoPunti.count >= 3 { selezionaDaPoligono(lassoPunti) }
                case .rettangolo:
                    if let a = rettInizio { selezionaDaRettangolo(a, p) }
                case .pennello, .tocco, .seleziona:
                    break   // selezione già applicata in continuo / nessun pan
                }
                lassoPunti = []; rettInizio = nil; cacheSchermo = []
                lassoLayer?.path = nil
            default:
                break
            }
        }

        /// Proietta tutti i baricentri dei triangoli in coordinate schermo.
        // z-buffer grezzo per la selezione: distanza minima dalla camera per cella
        // schermo → si tiene solo il layer frontale (no facce dietro/occluse).
        private var depthGrid: [Int: Float] = [:]
        private var depthTol: Float = 1
        private let cellaPx: CGFloat = 14
        private func cella(_ p: CGPoint) -> Int { Int(p.y / cellaPx) &* 4096 &+ Int(p.x / cellaPx) }

        @MainActor private func proiettaCentroidi(in v: SCNView) {
            let tris = model.mesh.triangles
            let cam = v.pointOfView?.simdWorldPosition ?? SIMD3<Float>(0, 0, 0)
            var out: [(Int, CGPoint)] = []
            out.reserveCapacity(tris.count)
            depthGrid.removeAll(keepingCapacity: true)
            // tolleranza ~5% del lato mesh: assorbe lo spessore del muro, scarta il fondo
            depthTol = model.estensioneLato * 0.05
            for i in tris.indices {
                let c = model.mesh.centroid(tris[i])
                let sp = v.projectPoint(SCNVector3(c.x, c.y, c.z))
                guard sp.z > 0, sp.z < 1 else { continue }
                let p = CGPoint(x: CGFloat(sp.x), y: CGFloat(sp.y))
                let dist = simd_length(c - cam)
                out.append((i, p))
                let k = cella(p)
                if let m = depthGrid[k] { if dist < m { depthGrid[k] = dist } } else { depthGrid[k] = dist }
                // memorizza la distanza accanto allo screen point
                distCache[i] = dist
            }
            cacheSchermo = out
        }

        private var distCache: [Int: Float] = [:]

        /// True se il triangolo `i` (a schermo `p`) è nel layer frontale della sua cella.
        @MainActor private func visibile(_ i: Int, _ p: CGPoint) -> Bool {
            guard let d = distCache[i], let m = depthGrid[cella(p)] else { return true }
            return d <= m + depthTol
        }

        @MainActor private func selezionaDaPoligono(_ poly: [CGPoint]) {
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo where puntoInPoligono(sp, poly) && visibile(i, sp) { sel.insert(i) }
            model.applicaLazo(sel, aggiungi: model.selezioneAdditiva)
        }

        @MainActor private func selezionaDaRettangolo(_ a: CGPoint, _ b: CGPoint) {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo where r.contains(sp) && visibile(i, sp) { sel.insert(i) }
            model.applicaLazo(sel, aggiungi: model.selezioneAdditiva)
        }

        /// Pennello §3: assegna i triangoli sotto il dito alla faccia attiva.
        @MainActor private func handlePanFacce(_ g: UIPanGestureRecognizer, in v: SCNView) {
            let p = g.location(in: v)
            // Fase C: se un trascinamento di maniglia è in corso, muovi (delta dall'origine).
            if let tr = trascina {
                switch g.state {
                case .changed:
                    if let cur = puntoSulPiano(p, p: tr.p, n: tr.n, in: v) {
                        let delta = cur - tr.start
                        if tr.edge {
                            let k1 = (tr.k + 1) % tr.orig.count
                            model.spostaEdgePoligono(faccia: tr.faccia, edge: tr.k,
                                                     a: tr.orig[tr.k] + delta, tr.orig[k1] + delta)
                        } else {
                            model.spostaVerticePoligono(faccia: tr.faccia, indice: tr.k,
                                                        a: tr.orig[tr.k] + delta)
                        }
                    }
                case .ended, .cancelled:
                    trascina = nil
                default: break
                }
                return
            }
            // All'inizio di un pan: se parte su una maniglia, avvia il trascinamento.
            if g.state == .began, let m = maniglia(sotto: p, in: v),
               let pian = model.pianoFaccia(m.faccia), let orig = model.poligonoDi(m.faccia),
               let start = puntoSulPiano(p, p: pian.p, n: pian.n, in: v) {
                model.facciaAttivaId = m.faccia
                model.registraUndo()
                trascina = Trascina(faccia: m.faccia, edge: m.edge, k: m.k,
                                    p: pian.p, n: pian.n, start: start, orig: orig)
                return
            }
            // Il pan marca una SELEZIONE secondo il modo (pennello/rettangolo/lazo).
            // In modo "tocco" il pan non fa nulla (si marca con i tap → semi).
            switch g.state {
            case .began:
                proiettaCentroidi(in: v)
                catturaNormaleRif(p, in: v)
                rettInizio = p
                lassoPunti = [p]
                if model.modoSelezione == .pennello {
                    model.applicaLazo([], aggiungi: model.selezioneAdditiva); pennella(p)
                }
            case .changed:
                switch model.modoSelezione {
                case .lazo:       lassoPunti.append(p); aggiornaTracciato(chiusa: true)
                case .rettangolo: aggiornaRettangolo(da: rettInizio ?? p, a: p)
                case .pennello:   pennella(p); disegnaCerchioPennello(p)
                case .tocco, .seleziona: break
                }
            case .ended, .cancelled:
                switch model.modoSelezione {
                case .lazo:
                    aggiornaTracciato(chiusa: true)
                    if lassoPunti.count >= 3 { selezionaDaPoligono(lassoPunti) }
                case .rettangolo:
                    if let a = rettInizio { selezionaDaRettangolo(a, p) }
                case .pennello, .tocco, .seleziona:
                    break
                }
                lassoPunti = []; rettInizio = nil; cacheSchermo = []; lassoLayer?.path = nil
            default:
                break
            }
        }

        @MainActor private func pennellaFacce(_ p: CGPoint) {
            let r2 = raggioPennello * raggioPennello
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo {
                let dx = sp.x - p.x, dy = sp.y - p.y
                if dx * dx + dy * dy <= r2 && passaNormale(i) && visibile(i, sp) { sel.insert(i) }
            }
            if !sel.isEmpty { model.assegnaAFacciaAttiva(sel) }
        }

        @MainActor private func pennella(_ p: CGPoint) {
            let r2 = raggioPennello * raggioPennello
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo {
                let dx = sp.x - p.x, dy = sp.y - p.y
                if dx * dx + dy * dy <= r2 && passaNormale(i) && visibile(i, sp) { sel.insert(i) }
            }
            if !sel.isEmpty { model.aggiungiAllaSelezione(sel) }
        }

        private func aggiornaRettangolo(da a: CGPoint, a b: CGPoint) {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            lassoLayer?.path = UIBezierPath(rect: r).cgPath
        }

        @MainActor private func disegnaCerchioPennello(_ p: CGPoint) {
            let r = CGRect(x: p.x - raggioPennello, y: p.y - raggioPennello,
                           width: raggioPennello * 2, height: raggioPennello * 2)
            lassoLayer?.path = UIBezierPath(ovalIn: r).cgPath
        }

        // Trascinamento di una maniglia del box lungo il suo asse.
        private var facciaBox: FacciaBox?
        private var profonditaManiglia: Float = 0

        @MainActor private func handlePanBox(_ g: UIPanGestureRecognizer, in v: SCNView) {
            let p = g.location(in: v)
            switch g.state {
            case .began:
                let hits = v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
                cerca: for h in hits {
                    var n: SCNNode? = h.node
                    while let cur = n {   // risali da anello/nucleo al nodo "box:…"
                        if let f = model.facciaBox(perNome: cur.name) {
                            facciaBox = f
                            let c = model.centroFaccia(f)
                            profonditaManiglia = v.projectPoint(SCNVector3(c.x, c.y, c.z)).z
                            break cerca
                        }
                        n = cur.parent
                    }
                }
            case .changed:
                guard let f = facciaBox else { return }
                let w = v.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), profonditaManiglia))
                // Porta il punto nel frame LOCALE del box, poi prendi l'asse.
                let local = model.worldInLocaleBox(SIMD3(w.x, w.y, w.z))
                model.aggiornaFacciaBox(f, coord: local[f.asse])
            case .ended, .cancelled:
                facciaBox = nil
            default:
                break
            }
        }

        private func aggiornaTracciato(chiusa: Bool) {
            guard lassoPunti.count >= 2 else { lassoLayer?.path = nil; return }
            let path = UIBezierPath()
            path.move(to: lassoPunti[0])
            for q in lassoPunti.dropFirst() { path.addLine(to: q) }
            if chiusa { path.close() }
            lassoLayer?.path = path.cgPath
        }

        private func puntoInPoligono(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
            guard poly.count >= 3 else { return false }
            var dentro = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let a = poly[i], b = poly[j]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                    dentro.toggle()
                }
                j = i
            }
            return dentro
        }

        private func discendente(_ n: SCNNode, di root: SCNNode) -> Bool {
            var cur: SCNNode? = n
            while let c = cur { if c === root { return true }; cur = c.parent }
            return false
        }
    }
}

// MARK: – Strutture export proxy (§9)

private extension SIMD3 where Scalar == Float {
    var lista: [Float] { [x, y, z] }
}

private struct MeshInfoJSON: Codable { let vertici: Int; let triangoli: Int }
private struct PianoJSON: Codable { let punto: [Float]; let normale: [Float] }
private struct PianoBaseJSON: Codable {
    let origine: [Float]; let normale: [Float]; let right: [Float]; let up: [Float]
}
private struct FacciaOverrideJSON: Codable {
    let id: Int; let nome: String; let tipo: String; let colore: String
    let priorita: Int; let n_triangoli: Int; let triangoli: [Int]; let piano: PianoJSON?
}
private struct ProxyOverridesJSON: Codable {
    let versione: Int; let stato: String; let mesh: MeshInfoJSON
    let piano_base: PianoBaseJSON?; let facce: [FacciaOverrideJSON]
}
private struct PianoProxyJSON: Codable {
    let id: Int; let nome: String; let tipo: String; let priorita: Int
    let punto: [Float]; let normale: [Float]
}
private struct MultipianoJSON: Codable {
    let versione: Int; let stato: String
    let piano_base: PianoBaseJSON?; let piani: [PianoProxyJSON]
}

// MARK: – Modello: scena, camera, caricamento mesh

/// Strumento attivo nell'editor 3D.
/// Dati 2D per il pannello "rileva perimetro" (coordinate u,v nel piano di slice).
struct PerimetroDisegno {
    var segmenti: [(CGPoint, CGPoint)] = []
    var punti: [CGPoint] = []
    var spline: [CGPoint] = []
    var bounds: CGRect = .zero
}

/// Pannello 2D top-down della sezione: mostra il bordo (ciano) e lo ricalca a
/// linea/spline (giallo). Tap = aggiunge un punto. Disaccoppiato dalla camera 3D
/// (la sezione di una facciata è una curva piana: niente "sparizione" di geometria).
private struct PannelloPerimetro: View {
    @ObservedObject var model: Mesh3DModel

    var body: some View {
        GeometryReader { geo in
            let d = model.disegnoPerimetro
            let b = d.bounds
            let pad: CGFloat = 28
            let scala: CGFloat = (b.width > 0 && b.height > 0)
                ? min((geo.size.width - 2 * pad) / b.width, (geo.size.height - 2 * pad) / b.height)
                : 1
            let offX = (geo.size.width - b.width * scala) / 2
            let offY = (geo.size.height - b.height * scala) / 2
            let toView = { (p: CGPoint) -> CGPoint in
                CGPoint(x: offX + (p.x - b.minX) * scala, y: offY + (b.maxY - p.y) * scala)
            }
            let toUV = { (p: CGPoint) -> CGPoint in
                CGPoint(x: b.minX + (p.x - offX) / scala, y: b.maxY - (p.y - offY) / scala)
            }
            ZStack {
                Color.black.opacity(0.9)
                Canvas { ctx, _ in
                    var sp = Path()
                    for s in d.segmenti { sp.move(to: toView(s.0)); sp.addLine(to: toView(s.1)) }
                    ctx.stroke(sp, with: .color(.teal), lineWidth: 1.5)
                    for s in d.segmenti {
                        let m = CGPoint(x: (s.0.x + s.1.x) / 2, y: (s.0.y + s.1.y) / 2)
                        let v = toView(m)
                        ctx.fill(Path(ellipseIn: CGRect(x: v.x - 1.5, y: v.y - 1.5, width: 3, height: 3)), with: .color(.teal))
                    }
                    if d.spline.count >= 2 {
                        var yp = Path(); yp.move(to: toView(d.spline[0]))
                        for q in d.spline.dropFirst() { yp.addLine(to: toView(q)) }
                        ctx.stroke(yp, with: .color(.yellow), lineWidth: 2.5)
                    }
                    for q in d.punti {
                        let v = toView(q)
                        ctx.fill(Path(ellipseIn: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)), with: .color(.yellow))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { val in
                    guard b.width > 0 else { return }
                    model.toccaUV(toUV(val.location))
                })
                if b.width == 0 {
                    Text("Nessuna sezione a questa quota — sposta lo slider")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                VStack {
                    HStack {
                        Text("Sezione dall'alto · ricalca il bordo")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                        Spacer()
                    }.padding(12)
                    Spacer()
                }
            }
        }
    }
}

enum StrumentoMesh3D: String, CaseIterable, Identifiable {
    case orbita     // naviga (orbit/pan/zoom)
    case box        // box di lavoro + crop
    case seleziona  // lazo a mano libera per selezionare triangoli
    case facce      // pennelli colorati: assegna triangoli a facce/piani
    case punti      // piano livello-zero: 3+ punti sul muro → piano medio

    var id: String { rawValue }
    var icona: String {
        switch self {
        case .orbita:    return "hand.draw"
        case .box:       return "cube"
        case .seleziona: return "lasso"
        case .facce:     return "square.stack.3d.up"
        case .punti:     return "square.3.layers.3d.top.filled"
        }
    }
    var etichetta: String {
        switch self {
        case .orbita:    return "Naviga"
        case .box:       return "Box"
        case .seleziona: return "Seleziona"
        case .facce:     return "Piani"
        case .punti:     return "Piano base"
        }
    }
}

/// Modo di selezione (§2): lazo libero, rettangolo, pennello.
enum ModoSelezione: String, CaseIterable, Identifiable {
    case seleziona, tocco, pennello, rettangolo, lazo
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .seleziona:  return "Seleziona"
        case .tocco:      return "Tocco"
        case .pennello:   return "Pennello"
        case .rettangolo: return "Rettangolo"
        case .lazo:       return "Lazo"
        }
    }
    var icona: String {
        switch self {
        case .seleziona:  return "hand.point.up.left"
        case .tocco:      return "hand.tap"
        case .pennello:   return "paintbrush.pointed"
        case .rettangolo: return "rectangle.dashed"
        case .lazo:       return "lasso"
        }
    }
    /// Modi che producono una selezione di triangoli col pan (vs tocco/seleziona).
    var disegnaSelezione: Bool { self == .pennello || self == .rettangolo || self == .lazo }
}

/// Faccia del box di lavoro trascinabile (una maniglia per lato).
enum FacciaBox: String {
    case xMin, xMax, yMin, yMax, zMin, zMax
    var asse: Int { (self == .xMin || self == .xMax) ? 0 : (self == .yMin || self == .yMax) ? 1 : 2 }
    var isMin: Bool { self == .xMin || self == .yMin || self == .zMin }
}

@MainActor
final class Mesh3DModel: ObservableObject {
    let nome: String
    let scene = SCNScene()
    let contentNode = SCNNode()   // contiene SOLO la mesh (editabile)
    private let selectionNode = SCNNode()  // overlay dei triangoli selezionati
    private let facceProxyNode = SCNNode()  // overlay colorato delle facce proxy
    private let markersNode = SCNNode()  // punti in corso (sfere + polilinea), world space
    private let lineNode = SCNNode()     // polilinea della faccia in costruzione
    private let pianoBaseNode = SCNNode() // quad del piano livello-zero (§4)
    private let pianiNode = SCNNode()     // quad dei piani proxy fittati (§6)
    private let semiNode = SCNNode()      // puntini-seme del flusso rapido "Tocca semi"
    private let perimetroNode = SCNNode() // slice orizzontale + traccia del perimetro
    private let cursoreNode = SCNNode()   // mirino 3D d'ispezione

    @Published var numVertici = 0
    @Published var numTriangoli = 0
    @Published var caricamento = false
    @Published var errore: String?
    /// Incrementato per chiedere alla vista una re-inquadratura (frameNodes).
    @Published var reframeTick = 0

    @Published var strumento: StrumentoMesh3D = .orbita {
        didSet { boxNode.isHidden = strumento != .box; aggiornaClip() }
    }

    // Box di lavoro orientato (§1): origine + assi `boxRot` (NON ruota la mesh),
    // bounds `boxLo/boxHi` espressi nel frame locale del box.
    private let boxNode = SCNNode()
    private(set) var frameOrigin = SIMD3<Float>(repeating: 0)
    private(set) var boxRot = matrix_identity_float3x3
    private(set) var boxLo = SIMD3<Float>(repeating: -1)
    private(set) var boxHi = SIMD3<Float>(repeating: 1)

    // Selezione + taglio (T1)
    private(set) var mesh = EditableMesh(vertices: [], triangles: [])
    /// Mesh come caricata (prima di crop/pulizia): per "riparti da zero".
    private var meshOriginale: EditableMesh?
    /// Adiacenza saldata in cache (ricostruita pigramente): velocizza ogni crescita.
    private var adiacenzaCache: EditableMesh.Adiacenza?
    func adiacenza() -> EditableMesh.Adiacenza {
        if let a = adiacenzaCache { return a }
        let a = mesh.costruisciAdiacenza(); adiacenzaCache = a; return a
    }
    private(set) var selezione = Set<Int>()
    @Published var numSelezionati = 0
    @Published var modoSelezione: ModoSelezione = .seleziona
    /// Le nuove selezioni si sommano invece di sostituire (più zone insieme).
    @Published var selezioneAdditiva = false
    /// Flusso rapido: ogni tocco lascia un seme; "Cresci tutti" li fa crescere insieme.
    @Published var modoSemi = false
    @Published private(set) var numSemi = 0
    private var semiTocco: [(tri: Int, punto: SIMD3<Float>)] = []
    // Rileva perimetro: slice orizzontale + tracciamento del perimetro a punti.
    @Published var modoPerimetro = false
    @Published var perimetroTraccia = false   // false = posiziona sezione su 3D; true = traccia 2D
    @Published var chiudiPerimetro = false { didSet { aggiornaSlice() } }   // chiusura opzionale (default aperto)
    @Published var quotaSlice: Float = 0.5 { didSet { aggiornaSlice() } }
    @Published private(set) var numPuntiPerimetro = 0
    private var puntiPerimetro: [SIMD3<Float>] = []
    private var ultimaSezione: [(SIMD3<Float>, SIMD3<Float>)] = []   // segmenti per l'auto-angoli
    private var sliceS0: Float = 0   // quota assoluta del piano di slice (lungo su)
    private var prevMostraMesh = true   // ripristino visibilità mesh uscendo dal perimetro
    private var perimE1 = SIMD3<Float>(1, 0, 0)   // base orizzontale 2D del piano di slice
    private var perimE2 = SIMD3<Float>(0, 0, 1)
    /// Dati per il pannello 2D del perimetro (coordinate u,v nel piano orizzontale).
    @Published private(set) var disegnoPerimetro = PerimetroDisegno()
    // Pennello: dimensione + vincolo alle normali della geometria
    @Published var raggioPennello: CGFloat = 42
    @Published var vincolaNormali = false
    @Published var tolleranzaNormaleGradi: Double = 30

    // Facce proxy (§3): pennelli colorati = facce/piani
    @Published var facce: [FacciaProxy] = []
    @Published var facciaAttivaId: Int?
    @Published var pianiGenerati = 0
    private var prossimoIdFaccia = 1

    // Cursore d'ispezione 3D
    @Published var cursoreInfo: String?

    // ViewCube / navigazione
    @Published var cameraQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    @Published var autoRuota = false
    /// Impostato dal container: applica l'orientamento camera (dir, up).
    var richiediSnap: ((SIMD3<Float>, SIMD3<Float>) -> Void)?

    /// Snap della vista lungo una direzione (assi del piano base se c'è).
    func snapVista(_ dir: SIMD3<Float>) {
        let d = simd_normalize(dir)
        let up: SIMD3<Float> = abs(simd_dot(d, assiRif.u)) > 0.9 ? assiRif.r : assiRif.u
        richiediSnap?(d, up)
    }
    func snapFronte()   { snapVista(assiRif.n) }
    func snapAlto()     { snapVista(assiRif.u) }
    func snapDestra()   { snapVista(assiRif.r) }
    func snapIso()      { snapVista(assiRif.n + assiRif.r * 0.7 + assiRif.u * 0.6) }

    /// Snap dal ViewCube: asse 0=right,1=up,2=normale, con segno.
    func snapAsse(_ idx: Int, _ segno: Float) {
        let a = assiRif
        let d = idx == 0 ? a.r : (idx == 1 ? a.u : a.n)
        snapVista(d * segno)
    }

    /// Auto-rotazione (turntable) attorno al centro mesh; off → ripristina l'orientamento.
    func toggleAutoRuota() {
        autoRuota.toggle()
        if autoRuota {
            let (lo, hi) = mesh.aabb
            let c = (lo + hi) / 2
            contentNode.pivot = SCNMatrix4MakeTranslation(c.x, c.y, c.z)
            contentNode.position = SCNVector3(c.x, c.y, c.z)
            let axis = haPianoBase ? pianoBaseUp : SIMD3<Float>(0, 1, 0)
            let rot = SCNAction.rotate(by: .pi * 2, around: SCNVector3(axis.x, axis.y, axis.z), duration: 16)
            contentNode.runAction(.repeatForever(rot), forKey: "spin")
        } else {
            contentNode.removeAction(forKey: "spin")
            contentNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            contentNode.pivot = SCNMatrix4Identity
            contentNode.position = SCNVector3Zero
        }
    }

    // Validazione (§8)
    @Published var mostraProxy = true { didSet { aggiornaVista() } }
    @Published var vistaValidazione: VistaValidazione = .normale { didSet { aggiornaVista() } }
    @Published var mostraPiani = false { didSet { ridisegnaPiani() } }
    /// Mostra/nasconde la geometria OC grigia editabile.
    @Published var mostraMesh = true { didSet { aggiornaVista() } }
    /// Attiva la versione texturizzata OC (nodo originale tenuto nascosto).
    @Published var mostraTexturaOC = false { didSet { aggiornaVista() } }
    /// Nodo texturizzato OC originale (estratto al caricamento, normalmente nascosto).
    private var ocTextureNode: SCNNode?
    var haTexturaOC: Bool { ocTextureNode != nil }
    @Published var puoUndo = false
    @Published var puoRedo = false
    private var undoStack: [(EditableMesh, Set<Int>, [FacciaProxy])] = []
    private var redoStack: [(EditableMesh, Set<Int>, [FacciaProxy])] = []
    private let maxUndo = 8

    // Creazione faccia per punti
    @Published var numPuntiFaccia = 0
    private var puntiFaccia: [SCNVector3] = []
    private var raggioMarker: CGFloat = 0.05   // dimensione sfere, scalata sulla mesh
    private var estensioneMesh: Float = 1      // lato maggiore della mesh
    /// Soglia di planarità "buona" per le facce (1% del lato mesh).
    var sogliaErrore: Float { estensioneMesh * 0.01 }
    /// Lato maggiore della mesh (per soglie geometriche esterne, es. occlusione).
    var estensioneLato: Float { estensioneMesh }
    /// (#15) Verso "su" stimato dalla mesh (media delle facce orizzontali). Default
    /// world-Y; va sostituibile col vettore gravità reale delle pose ARKit.
    private(set) var gravitaSu = SIMD3<Float>(0, 1, 0)

    // Piano livello-zero (§4)
    @Published var haPianoBase = false
    private(set) var pianoBaseOrigine = SIMD3<Float>(repeating: 0)
    private(set) var pianoBaseNormale = SIMD3<Float>(0, 0, 1)
    private(set) var pianoBaseRight = SIMD3<Float>(1, 0, 0)
    private(set) var pianoBaseUp = SIMD3<Float>(0, 1, 0)

    init(meshFile: URL?, nome: String) {
        self.nome = nome
        configuraScena()
        // Sorgente, in ordine: file passato (download backend) → mesh OC reale
        // precaricata nel bundle (facciata_demo.obj) → mesh procedurale.
        let file = meshFile
            ?? Bundle.main.url(forResource: "facciata_demo", withExtension: "obj")
        if let file {
            caricamento = true
            Task { await caricaFile(file) }
        } else {
            let demo = MeshFactory.demoMesh()
            meshOriginale = demo
            installaMesh(demo)
        }
    }

    /// Ricarica la mesh originale e azzera tutto (facce, selezione, crop, undo).
    func ricaricaDaCapo() {
        guard let orig = meshOriginale else { return }
        installaMesh(orig)
    }

    private func configuraScena() {
        scene.background.contents = UIColor(EditorTheme.bg)
        scene.rootNode.addChildNode(contentNode)
        contentNode.addChildNode(facceProxyNode)
        contentNode.addChildNode(selectionNode)
        boxNode.isHidden = true
        contentNode.addChildNode(boxNode)
        scene.rootNode.addChildNode(pianoBaseNode)
        contentNode.addChildNode(pianiNode)
        contentNode.addChildNode(semiNode)
        contentNode.addChildNode(perimetroNode)
        cursoreNode.isHidden = true
        contentNode.addChildNode(cursoreNode)
        markersNode.addChildNode(lineNode)
        scene.rootNode.addChildNode(markersNode)

        // Key light direzionale + ambient soft: stacco di rilievo sulle
        // sporgenze. La camera la gestisce il defaultCameraController (orbit).
        let key = SCNNode()
        key.light = SCNLight(); key.light!.type = .directional
        key.light!.intensity = 700
        key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)

        let amb = SCNNode()
        amb.light = SCNLight(); amb.light!.type = .ambient
        amb.light!.intensity = 400
        scene.rootNode.addChildNode(amb)
    }

    private static let coloreMesh = UIColor(white: 0.66, alpha: 1)

    /// Installa la mesh editabile: render, statistiche, scala marker, frame.
    private func installaMesh(_ m: EditableMesh) {
        mesh = m
        selezione = []
        facce = []; facciaAttivaId = nil; pianiGenerati = 0; mostraPiani = false
        haPianoBase = false; renderPianoBase(); annullaFaccia(); nascondiCursore()
        undoStack = []; redoStack = []
        puoUndo = false; puoRedo = false
        renderMesh()
        calcolaScala()
        allineaBox()        // default: box allineato alla geometria (mesh storte)
        inquadra()
    }

    /// (Ri)costruisce la geometria SceneKit dalla mesh editabile + overlay selezione.
    private func renderMesh() {
        adiacenzaCache = nil   // la mesh è cambiata: invalida l'adiacenza in cache
        contentNode.geometry = mesh.scnGeometry(colore: Self.coloreMesh)
        numVertici = mesh.vertexCount
        numTriangoli = mesh.triangleCount
        ridisegnaSelezione()
        aggiornaVista()   // riapplica trasparenza mesh + overlay facce
        aggiornaClip()    // ri-applica il clip box (materiale ricreato)
    }

    private func ridisegnaSelezione() {
        selectionNode.geometry = mesh.selezioneGeometry(
            selezione, colore: UIColor(EditorTheme.accento).withAlphaComponent(0.55))
        numSelezionati = selezione.count
    }

    /// Scala i marker dei punti in base all'estensione della mesh (le coordinate
    /// OC sono arbitrarie: una sfera fissa sarebbe invisibile o gigante).
    private func calcolaScala() {
        let bb = contentNode.flattenedClone().boundingBox
        let ext = max(bb.max.x - bb.min.x, max(bb.max.y - bb.min.y, bb.max.z - bb.min.z))
        estensioneMesh = ext
        raggioMarker = CGFloat(max(ext * 0.012, 0.001))
        // Mirino: sfera arancione + croce bianca, sempre sopra la mesh.
        let sfera = SCNSphere(radius: CGFloat(ext * 0.008))
        let ms = SCNMaterial(); ms.diffuse.contents = UIColor(EditorTheme.accento)
        ms.lightingModel = .constant; ms.readsFromDepthBuffer = false
        sfera.materials = [ms]
        cursoreNode.geometry = sfera
        cursoreNode.childNodes.forEach { $0.removeFromParentNode() }
        cursoreNode.addChildNode(SCNNode(geometry: MeshFactory.croce3D(ext * 0.05, colore: .white)))
    }

    /// Posiziona il mirino sul punto toccato e dice su che faccia si trova.
    func posizionaCursore(_ punto: SCNVector3, triangolo: Int) {
        cursoreNode.position = punto
        cursoreNode.isHidden = false
        if let f = facce.first(where: { $0.triangoli.contains(triangolo) }) {
            cursoreInfo = "\(f.nome) · \(f.tipo.etichetta) · \(f.triangoli.count) tri"
        } else if facce.isEmpty {
            cursoreInfo = "nessuna faccia marcata"
        } else {
            cursoreInfo = "fuori dalle facce"
        }
    }

    func nascondiCursore() {
        cursoreNode.isHidden = true
        cursoreInfo = nil
    }

    private func caricaFile(_ url: URL) async {
        do {
            // SceneKit/ModelIO caricano OBJ, USDZ, PLY, SCN, DAE da file.
            let loaded = try SCNScene(url: url, options: [.checkConsistency: true])
            let radice = SCNNode()
            for child in loaded.rootNode.childNodes { radice.addChildNode(child) }
            // Attacca temporaneamente per avere i worldTransform corretti, poi
            // estrai i buffer editabili e sostituisci con la geometria unica.
            contentNode.addChildNode(radice)
            if let em = EditableMesh.from(node: radice) {
                // Conserva il nodo texturizzato OC (nascosto + non selezionabile)
                // per il toggle "Texture OC", invece di scartarlo.
                radice.isHidden = true
                radice.enumerateHierarchy { n, _ in n.categoryBitMask = 0 }
                ocTextureNode = radice
                meshOriginale = em
                installaMesh(em)
            } else {
                errore = "Mesh senza triangoli leggibili"
            }
        } catch {
            errore = "Mesh non caricabile: \(error.localizedDescription)"
        }
        caricamento = false
    }

    /// Chiede alla vista di re-inquadrare tutta la mesh (frameNodes del
    /// camera controller). La mesh OC è in coordinate arbitrarie: nessuna
    /// assunzione su scala/origine.
    func inquadra() { reframeTick += 1 }

    /// Buffer della mesh editabile (per il taglio distruttivo, Fase 3).
    /// Disponibile solo quando la mesh è una geometria singola (demo / OBJ
    /// flatten futuro), non per gerarchie multi-nodo.
    var geometriaEditabile: SCNGeometry? { contentNode.geometry }

    // MARK: Box di lavoro + crop (§1)

    /// Allinea il box alla facciata: se c'è il piano base usa quello (preciso),
    /// altrimenti la PCA della geometria. NON ruota la mesh, solo il box.
    func allineaBox() {
        if haPianoBase { allineaBoxAlPianoBase(); return }
        // Piano dominante (facciata) via RANSAC; fallback PCA grezza.
        let ob = mesh.orientedBoxRANSAC() ?? mesh.orientedBox()
        frameOrigin = ob.origin
        boxRot = ob.rot
        let margine = (ob.hi - ob.lo) * 0.02
        boxLo = ob.lo - margine
        boxHi = ob.hi + margine
        ricostruisciBox()
    }

    /// Reset assi-allineato al mondo (box dritto sul bounding box della mesh).
    func resetBox() {
        boxRot = matrix_identity_float3x3
        frameOrigin = .zero
        let (lo, hi) = mesh.aabb
        let margine = (hi - lo) * 0.02
        boxLo = lo - margine
        boxHi = hi + margine
        ricostruisciBox()
    }

    /// Aggiorna una faccia del box trascinata (coord nel frame LOCALE del box).
    func aggiornaFacciaBox(_ f: FacciaBox, coord: Float) {
        let a = f.asse
        let minimo: Float = 1e-4
        if f.isMin { boxLo[a] = min(coord, boxHi[a] - minimo) }
        else       { boxHi[a] = max(coord, boxLo[a] + minimo) }
        ricostruisciBox()
    }

    /// Crop: elimina i poligoni fuori dal box orientato (o dentro, se `inverti`).
    func applicaCrop(inverti: Bool) {
        let sel = inverti ? mesh.triangoliDentro(frameOrigin, boxRot, boxLo, boxHi)
                          : mesh.triangoliFuori(frameOrigin, boxRot, boxLo, boxHi)
        guard !sel.isEmpty else { return }
        registraUndo()
        let remap = mesh.elimina(sel)
        rimappaFacce(remap)
        selezione = []
        renderMesh()
    }

    /// Hit-test sulle maniglie del box (dal Coordinator). Ritorna la faccia.
    func facciaBox(perNome nome: String?) -> FacciaBox? {
        guard let n = nome, n.hasPrefix("box:") else { return nil }
        return FacciaBox(rawValue: String(n.dropFirst(4)))
    }

    /// Centro di una faccia in coordinate LOCALI del box.
    private func centroFacciaLocale(_ f: FacciaBox) -> SIMD3<Float> {
        var p = (boxLo + boxHi) / 2
        p[f.asse] = f.isMin ? boxLo[f.asse] : boxHi[f.asse]
        return p
    }

    /// Centro di una faccia in WORLD (per profondità/drag dal Coordinator).
    func centroFaccia(_ f: FacciaBox) -> SIMD3<Float> {
        frameOrigin + boxRot * centroFacciaLocale(f)
    }

    /// Converte un punto world nel frame locale del box (per il drag maniglie).
    func worldInLocaleBox(_ w: SIMD3<Float>) -> SIMD3<Float> {
        boxRot.transpose * (w - frameOrigin)
    }

    /// Aggiorna i parametri di clip del materiale mesh dal box corrente.
    /// In modalità Box il clip è attivo → la mesh fuori dal box sparisce.
    private func aggiornaClip() {
        guard let mat = contentNode.geometry?.firstMaterial else { return }
        let rt = boxRot.transpose
        let t = -(rt * frameOrigin)
        let inv = simd_float4x4(
            SIMD4<Float>(rt.columns.0, 0),
            SIMD4<Float>(rt.columns.1, 0),
            SIMD4<Float>(rt.columns.2, 0),
            SIMD4<Float>(t, 1))
        mat.setValue(SCNVector3(boxLo.x, boxLo.y, boxLo.z), forKey: "clipLo")
        mat.setValue(SCNVector3(boxHi.x, boxHi.y, boxHi.z), forKey: "clipHi")
        mat.setValue(NSValue(scnMatrix4: SCNMatrix4(inv)), forKey: "clipInv")
        mat.setValue(Float(strumento == .box ? 1 : 0), forKey: "clipOn")
    }

    private func ricostruisciBox() {
        aggiornaClip()
        boxNode.isHidden = strumento != .box
        // Posiziona/orienta il nodo box; wireframe e maniglie sono in coord locali.
        let r0 = boxRot.columns.0, r1 = boxRot.columns.1, r2 = boxRot.columns.2
        boxNode.simdTransform = simd_float4x4(
            SIMD4(r0.x, r0.y, r0.z, 0),
            SIMD4(r1.x, r1.y, r1.z, 0),
            SIMD4(r2.x, r2.y, r2.z, 0),
            SIMD4(frameOrigin.x, frameOrigin.y, frameOrigin.z, 1))

        boxNode.childNodes.forEach { $0.removeFromParentNode() }
        boxNode.geometry = MeshFactory.boxWireframe(
            boxLo, boxHi, colore: UIColor(EditorTheme.accento))

        // Maniglie piccole tipo grip: un cubetto bianco bordo arancione al
        // centro di ogni faccia. Lato ≈ 1.5% del box (non più cerchioni).
        let ext = max(boxHi.x - boxLo.x, max(boxHi.y - boxLo.y, boxHi.z - boxLo.z))
        let s = CGFloat(max(ext * 0.018, 0.001))
        for f in [FacciaBox.xMin, .xMax, .yMin, .yMax, .zMin, .zMax] {
            let nodo = SCNNode()
            nodo.name = "box:\(f.rawValue)"
            let c = centroFacciaLocale(f)
            nodo.position = SCNVector3(c.x, c.y, c.z)
            // Cubo bianco + leggero alone arancione per la presa.
            let alone = SCNNode(geometry: SCNBox(width: s * 1.8, height: s * 1.8, length: s * 1.8, chamferRadius: s * 0.3))
            alone.geometry?.materials = [maniglia(UIColor(EditorTheme.accento).withAlphaComponent(0.5))]
            let grip = SCNNode(geometry: SCNBox(width: s, height: s, length: s, chamferRadius: s * 0.2))
            grip.geometry?.materials = [maniglia(.white)]
            nodo.addChildNode(alone)
            nodo.addChildNode(grip)
            boxNode.addChildNode(nodo)
        }
    }

    private func maniglia(_ colore: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // sempre visibili sopra la mesh
        m.writesToDepthBuffer = false
        return m
    }

    // MARK: Selezione + taglio (T1)

    func selezionaTutto() { selezione = Set(0..<mesh.triangleCount); ridisegnaSelezione() }
    func deselezionaTutto() { selezione = []; ridisegnaSelezione() }
    func invertiSelezione() {
        selezione = Set(0..<mesh.triangleCount).subtracting(selezione); ridisegnaSelezione()
    }
    func selezionaFrammenti() { selezione = mesh.frammenti(); ridisegnaSelezione() }
    func espandiSelezione() { selezione = mesh.espandi(selezione); ridisegnaSelezione() }
    func restringiSelezione() { selezione = mesh.restringi(selezione); ridisegnaSelezione() }

    /// Applica una selezione da lazo (calcolata dalla vista proiettando i
    /// triangoli). `aggiungi`: somma alla selezione invece di sostituirla.
    func applicaLazo(_ idx: Set<Int>, aggiungi: Bool) {
        selezione = aggiungi ? selezione.union(idx) : idx
        ridisegnaSelezione()
    }

    /// Aggiunge triangoli alla selezione (usato dal pennello, in continuo).
    func aggiungiAllaSelezione(_ idx: Set<Int>) {
        guard !idx.isSubset(of: selezione) else { return }
        selezione.formUnion(idx)
        ridisegnaSelezione()
    }

    /// Cancella i triangoli selezionati dalla mesh (distruttivo, con undo).
    func eliminaSelezione() {
        guard !selezione.isEmpty else { return }
        registraUndo()
        let remap = mesh.elimina(selezione)
        rimappaFacce(remap)
        selezione = []
        renderMesh()
    }

    func registraUndo() {
        undoStack.append((mesh, selezione, facce))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        puoUndo = true; puoRedo = false
    }

    func undo() {
        guard let (m, s, f) = undoStack.popLast() else { return }
        redoStack.append((mesh, selezione, facce))
        mesh = m; selezione = s; facce = f
        puoUndo = !undoStack.isEmpty; puoRedo = true
        renderMesh()
    }

    func redo() {
        guard let (m, s, f) = redoStack.popLast() else { return }
        undoStack.append((mesh, selezione, facce))
        mesh = m; selezione = s; facce = f
        puoUndo = true; puoRedo = !redoStack.isEmpty
        renderMesh()
    }

    // MARK: Facce proxy — pennelli colorati (§3)

    var facciaAttiva: FacciaProxy? { facce.first { $0.id == facciaAttivaId } }

    @Published var segmentando = false

    /// Riconosce le facce PARTENDO DAI SEGNI del pennello: per ogni faccia che
    /// ha una pennellata, cresce al suo piano (per appartenenza) e fitta il
    /// piano. Senza segni non rileva nulla. Off-main con spinner.
    func riconosciFacce() async {
        guard !segmentando else { return }
        let semi: [(id: Int, seed: Set<Int>)] = facce
            .filter { !$0.triangoli.isEmpty }
            .map { (id: $0.id, seed: $0.triangoli) }
        guard !semi.isEmpty else { return }   // niente segno → niente riconoscimento
        segmentando = true
        registraUndo()
        let m = mesh
        let tol = Float(tolleranzaNormaleGradi)
        let adj = adiacenza()   // costruita una volta, condivisa da tutti i semi
        let risultati = await Task.detached(priority: .userInitiated) {
            () -> [(id: Int, tri: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] in
            var out: [(Int, Set<Int>, SIMD3<Float>, SIMD3<Float>)] = []
            for s in semi {
                guard let (p, n) = m.fitPianoRANSAC(s.seed) else { continue }
                let cresciuto = m.crescePianare(da: s.seed, normale: n, punto: p, tolGradi: tol, adiacenza: adj)
                let (p2, n2) = m.fitPianoRANSAC(cresciuto) ?? (p, n)
                out.append((s.id, cresciuto, p2, n2))
            }
            return out
        }.value

        for r in risultati {
            guard let i = facce.firstIndex(where: { $0.id == r.id }) else { continue }
            for j in facce.indices where facce[j].id != r.id { facce[j].triangoli.subtract(r.tri) }
            facce[i].triangoli = r.tri
            facce[i].pianoPunto = r.punto
            facce[i].pianoNormale = r.normale
            facce[i].erroreRms = mesh.rmsDalPiano(r.tri, punto: r.punto, normale: r.normale)
        }
        mergeComplanariConnessi()      // #14
        stimaGravita()                 // #15
        scartaNonPlanari()             // #9
        scartaSlivers()                // #10
        scartaPianiPiccoli()           // #8
        snapManhattan()                // #12 + #13
        classificaPerGravita()         // #7
        generaPoligoniTutti()          // Fase B: poligono editabile per ogni piano
        if facciaAttivaId == nil || !facce.contains(where: { $0.id == facciaAttivaId }) {
            facciaAttivaId = facce.first?.id
        }
        pianiGenerati = facce.count
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
        segmentando = false
    }

    /// #14 — Unisce facce COMPLANARI e CONNESSE (stesso muro spezzato dalle
    /// finestre o segnato con più tratti). Due torrette complanari ma staccate
    /// NON si fondono (test `adiacenti`).
    private func mergeComplanariConnessi() {
        let tolOffset = estensioneMesh * 0.01   // ~1% del lato
        var unito = true
        while unito {
            unito = false
            ricerca: for i in facce.indices {
                for j in facce.indices where j > i {
                    guard let ni = facce[i].pianoNormale, let pi = facce[i].pianoPunto,
                          let nj = facce[j].pianoNormale, let pj = facce[j].pianoPunto,
                          !facce[i].triangoli.isEmpty, !facce[j].triangoli.isEmpty else { continue }
                    let paralleli = abs(simd_dot(ni, nj)) > 0.985
                    let stessoOffset = abs(simd_dot(pj - pi, ni)) < tolOffset
                    guard paralleli, stessoOffset,
                          mesh.adiacenti(facce[i].triangoli, facce[j].triangoli) else { continue }
                    facce[i].triangoli.formUnion(facce[j].triangoli)
                    if let (p2, n2) = mesh.fitPianoRANSAC(facce[i].triangoli) {
                        facce[i].pianoPunto = p2; facce[i].pianoNormale = n2
                        facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p2, normale: n2)
                    }
                    facce.remove(at: j)
                    unito = true
                    break ricerca
                }
            }
        }
    }

    /// #15 — Stima il verso "su" dalla mesh: media (pesata per area) delle normali
    /// delle facce ~orizzontali. Più affidabile di world-Y su modelli leggermente
    /// storti. Sostituibile col vettore gravità reale delle pose ARKit.
    private func stimaGravita() {
        let y = SIMD3<Float>(0, 1, 0)
        var acc = SIMD3<Float>(0, 0, 0); var peso: Float = 0
        for f in facce {
            guard let n = f.pianoNormale else { continue }
            let nn = simd_dot(n, y) < 0 ? -n : n           // orienta verso l'alto mondiale
            if abs(simd_dot(nn, y)) > 0.85 {               // faccia quasi orizzontale
                let a = mesh.areaTriangoli(f.triangoli)
                acc += nn * a; peso += a
            }
        }
        gravitaSu = (peso > 0 && simd_length(acc) > 1e-4) ? simd_normalize(acc) : y
    }

    /// #7 — Classifica ogni piano per angolo rispetto alla verticale (gravità stimata).
    private func classificaPerGravita() {
        for i in facce.indices {
            guard let n = facce[i].pianoNormale else { continue }
            let cosUp = abs(simd_dot(simd_normalize(n), gravitaSu))
            facce[i].tipo = cosUp > 0.7 ? .orizzontale : .facciata   // >70%≈ entro 45° dalla verticale
        }
    }

    /// #9 — Scarta i piani troppo poco planari (RMS alto = superficie curva/rumorosa,
    /// non un vero piano).
    private func scartaNonPlanari() {
        let maxRms = estensioneMesh * 0.03   // 3% del lato: ben oltre il rumore OC
        facce.removeAll { f in
            guard !f.triangoli.isEmpty, let p = f.pianoPunto, let n = f.pianoNormale else { return false }
            return mesh.rmsDalPiano(f.triangoli, punto: p, normale: n) > maxRms
        }
    }

    /// #10 — Scarta strisce/regioni mal proporzionate: bounding-box nel piano molto
    /// allungato (aspect estremo) o riempimento basso (frammenti sparsi).
    private func scartaSlivers() {
        facce.removeAll { f in
            guard !f.triangoli.isEmpty, let n = f.pianoNormale else { return false }
            var right = simd_cross(gravitaSu, n)
            if simd_length(right) < 1e-5 { right = simd_cross(SIMD3(1, 0, 0), n) }
            right = simd_normalize(right)
            let up = simd_normalize(simd_cross(n, right))
            var minx = Float.greatestFiniteMagnitude, maxx = -minx, miny = minx, maxy = -minx
            for i in f.triangoli {
                let c = mesh.centroid(mesh.triangles[i])
                let x = simd_dot(c, right), y = simd_dot(c, up)
                minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
            }
            let w = max(maxx - minx, 1e-5), h = max(maxy - miny, 1e-5)
            let fill = mesh.areaTriangoli(f.triangoli) / (w * h)
            let aspect = max(w, h) / min(w, h)
            return fill < 0.08 || aspect > 30
        }
    }

    /// #8 — Scarta i piani la cui area è sotto soglia (micro-piani / tratti non cresciuti).
    private func scartaPianiPiccoli() {
        let totale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        guard totale > 0 else { return }
        let minArea = totale * 0.001   // 0,1% dell'area totale della mesh
        facce.removeAll { !$0.triangoli.isEmpty && mesh.areaTriangoli($0.triangoli) < minArea }
    }

    // MARK: Editor poligonale (Fase B): poligono editabile + area metrica

    /// Genera il poligono editabile iniziale = rettangolo orientato del piano nel
    /// suo riferimento (assi `right`/`up` derivati da normale e gravità).
    func generaPoligono(perFaccia id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto, let n0 = facce[i].pianoNormale,
              !facce[i].triangoli.isEmpty else { return }
        let n = simd_normalize(n0)
        var right = simd_cross(gravitaSu, n)
        if simd_length(right) < 1e-5 { right = simd_cross(SIMD3(1, 0, 0), n) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(n, right))
        var minx = Float.greatestFiniteMagnitude, maxx = -minx, miny = minx, maxy = -minx
        for t in facce[i].triangoli {
            let tri = mesh.triangles[t]
            for v in [mesh.vertices[Int(tri.x)], mesh.vertices[Int(tri.y)], mesh.vertices[Int(tri.z)]] {
                let x = simd_dot(v - p, right), y = simd_dot(v - p, up)
                minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
            }
        }
        func pt(_ x: Float, _ y: Float) -> SIMD3<Float> { p + right * x + up * y }
        facce[i].poligono = [pt(minx, miny), pt(maxx, miny), pt(maxx, maxy), pt(minx, maxy)]
    }

    private func generaPoligoniTutti() { for f in facce { generaPoligono(perFaccia: f.id) } }

    /// Piano (punto, normale) della faccia, per il trascinamento delle maniglie.
    func pianoFaccia(_ id: Int) -> (p: SIMD3<Float>, n: SIMD3<Float>)? {
        guard let f = facce.first(where: { $0.id == id }),
              let p = f.pianoPunto, let n = f.pianoNormale else { return nil }
        return (p, simd_normalize(n))
    }

    /// Poligono corrente della faccia (per catturare l'origine del trascinamento).
    func poligonoDi(_ id: Int) -> [SIMD3<Float>]? { facce.first(where: { $0.id == id })?.poligono }

    /// Fase C — Sposta un intero edge `k` (vertici k e k+1) del poligono, sul piano,
    /// con snap di entrambi gli estremi (Fase D). Per "allungare" il poligono.
    func spostaEdgePoligono(faccia id: Int, edge k: Int, a p0: SIMD3<Float>, _ p1: SIMD3<Float>, snap: Bool = true) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              let n = facce[i].pianoNormale, let pp = facce[i].pianoPunto, k >= 0, k < poly.count else { return }
        let nn = simd_normalize(n)
        let k1 = (k + 1) % poly.count
        func proj(_ q: SIMD3<Float>) -> SIMD3<Float> { q - simd_dot(q - pp, nn) * nn }
        var a = proj(p0), b = proj(p1)
        if snap {
            if let ag = agganciaVertice(a, escludi: id, normalePiano: nn) { a = ag }
            if let bg = agganciaVertice(b, escludi: id, normalePiano: nn) { b = bg }
        }
        poly[k] = a; poly[k1] = b
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Splitta l'edge `k`: inserisce un vertice al suo punto medio (da quad a poligono).
    func splittaEdge(faccia id: Int, edge k: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              k >= 0, k < poly.count else { return }
        registraUndo()
        let k1 = (k + 1) % poly.count
        poly.insert((poly[k] + poly[k1]) * 0.5, at: k1)
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Aggancia l'edge più vicino del poligono attivo alla retta d'intersezione con
    /// la facciata di riferimento (la faccia più estesa con normale non parallela):
    /// spigolo condiviso esatto, senza trascinare a mano (es. spalletta↔facciata).
    func allineaAllaFacciata(_ id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              let nA0 = facce[i].pianoNormale, let pA = facce[i].pianoPunto, poly.count >= 2 else { return }
        let nA = simd_normalize(nA0)
        var rifN: SIMD3<Float>? = nil; var rifP = SIMD3<Float>(0, 0, 0); var areaMax: Float = 0
        for f in facce where f.id != id {
            guard let nB0 = f.pianoNormale, let pB = f.pianoPunto else { continue }
            if abs(simd_dot(simd_normalize(nB0), nA)) > 0.9 { continue }   // troppo parallela
            let a = mesh.areaTriangoli(f.triangoli)
            if a > areaMax { areaMax = a; rifN = simd_normalize(nB0); rifP = pB }
        }
        guard let nB = rifN else { return }
        let dir = simd_cross(nA, nB)
        guard simd_length(dir) > 1e-3 else { return }
        let u = simd_normalize(dir)
        guard let pL = puntoSuRetta(nA: nA, pA: pA, nB: nB, pB: rifP, dir: u) else { return }
        func suRetta(_ q: SIMD3<Float>) -> SIMD3<Float> { pL + u * simd_dot(q - pL, u) }
        var bestK = 0; var bestD = Float.greatestFiniteMagnitude
        for k in poly.indices {
            let mid = (poly[k] + poly[(k + 1) % poly.count]) * 0.5
            let d = simd_length(suRetta(mid) - mid)
            if d < bestD { bestD = d; bestK = k }
        }
        registraUndo()
        let k1 = (bestK + 1) % poly.count
        poly[bestK] = suRetta(poly[bestK]); poly[k1] = suRetta(poly[k1])
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Fase C — Sposta il vertice `k` del poligono della faccia `id` mantenendolo
    /// sul piano. Con `snap` cerca un aggancio (vertice/edge di altri piani, Fase D).
    func spostaVerticePoligono(faccia id: Int, indice k: Int, a posMondo: SIMD3<Float>, snap: Bool = true) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              var poly = facce[i].poligono, k >= 0, k < poly.count,
              let n = facce[i].pianoNormale, let p = facce[i].pianoPunto else { return }
        let nn = simd_normalize(n)
        var pos = posMondo - simd_dot(posMondo - p, nn) * nn   // resta sul piano
        if snap, let ag = agganciaVertice(pos, escludi: id, normalePiano: nn) { pos = ag }
        poly[k] = pos
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Fase D — Aggancio: prima ai vertici degli altri poligoni vicini, poi alla
    /// retta d'intersezione fra il piano corrente e quello del poligono vicino
    /// (spigolo condiviso, es. spalletta↔facciata). Ritorna la posizione agganciata.
    private func agganciaVertice(_ pos: SIMD3<Float>, escludi id: Int, normalePiano nA: SIMD3<Float>) -> SIMD3<Float>? {
        let soglia = estensioneMesh * 0.02   // ~2% del lato
        var miglior: SIMD3<Float>? = nil; var minD = soglia
        // 1) snap vertice→vertice
        for f in facce where f.id != id {
            for v in f.poligono ?? [] {
                let d = simd_length(v - pos)
                if d < minD { minD = d; miglior = v }
            }
        }
        if let m = miglior { return m }
        // 2) snap alla retta d'intersezione dei due piani (spigolo condiviso)
        for f in facce where f.id != id {
            guard let nB0 = f.pianoNormale, let pB = f.pianoPunto else { continue }
            let nB = simd_normalize(nB0)
            let dir = simd_cross(nA, nB)
            if simd_length(dir) < 1e-3 { continue }       // piani paralleli: nessuna retta
            let u = simd_normalize(dir)
            // un punto della retta: risolve il sistema dei due piani (minima norma)
            guard let pL = puntoSuRetta(nA: nA, pA: pos, nB: nB, pB: pB, dir: u) else { continue }
            let proj = pL + u * simd_dot(pos - pL, u)       // proiezione di pos sulla retta
            let d = simd_length(proj - pos)
            if d < minD { minD = d; miglior = proj }
        }
        return miglior
    }

    /// Un punto della retta d'intersezione dei piani A(nA,pA) e B(nB,pB) con
    /// direzione `dir`: risolve i due vincoli planari nel piano ⟂ a dir.
    private func puntoSuRetta(nA: SIMD3<Float>, pA: SIMD3<Float>,
                              nB: SIMD3<Float>, pB: SIMD3<Float>, dir: SIMD3<Float>) -> SIMD3<Float>? {
        let dA = simd_dot(nA, pA), dB = simd_dot(nB, pB)
        // base nel piano ⟂ a dir
        let e1 = simd_normalize(nA)
        let e2 = simd_normalize(simd_cross(dir, e1))
        // x = a*e1 + b*e2 ; nA·x = dA ; nB·x = dB
        let m00 = simd_dot(nA, e1), m01 = simd_dot(nA, e2)
        let m10 = simd_dot(nB, e1), m11 = simd_dot(nB, e2)
        let det = m00 * m11 - m01 * m10
        if abs(det) < 1e-6 { return nil }
        let a = (dA * m11 - m01 * dB) / det
        let b = (m00 * dB - dA * m10) / det
        return e1 * a + e2 * b
    }

    /// Area del poligono editabile, in unità mesh (shoelace 3D sul piano). Per i m²
    /// metrici va moltiplicata per il quadrato della scala mesh→metri.
    func areaPoligono(_ f: FacciaProxy) -> Float? {
        guard let poly = f.poligono, poly.count >= 3, let n = f.pianoNormale else { return nil }
        var s = SIMD3<Float>(0, 0, 0)
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            s += simd_cross(a, b)
        }
        return abs(simd_dot(s, simd_normalize(n))) * 0.5
    }

    // MARK: Fase A — semina rettangolare

    /// Cresce UN piano dal seme dato; ritorna l'id della faccia creata (o nil).
    @discardableResult
    private func creaPianoDa(seme: Set<Int>, adiacenza adj: EditableMesh.Adiacenza? = nil) -> Int? {
        guard let (p, n) = mesh.fitPianoRANSAC(seme) else { return nil }
        let tol = Float(tolleranzaNormaleGradi)
        let cresciuto = mesh.crescePianare(da: seme, normale: n, punto: p, tolGradi: tol, adiacenza: adj ?? adiacenza())
        let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) ?? (p, n)
        for j in facce.indices { facce[j].triangoli.subtract(cresciuto) }
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia, nome: "Piano \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.triangoli = cresciuto; f.pianoPunto = p2; f.pianoNormale = n2
        f.erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
        facce.append(f)
        return f.id
    }

    /// Aggiunge i triangoli SELEZIONATI al piano attivo (per completare porzioni
    /// che la crescita ha mancato), ne ricalcola il piano e ri-espande il poligono.
    func aggiungiSelezioneAlPianoAttivo() {
        guard !selezione.isEmpty, let id = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == id }) else { return }
        registraUndo()
        let nuovi = selezione
        for j in facce.indices where j != i { facce[j].triangoli.subtract(nuovi) }
        facce[i].triangoli.formUnion(nuovi)
        if let (p, n) = mesh.fitPianoRANSAC(facce[i].triangoli) {
            facce[i].pianoPunto = p; facce[i].pianoNormale = n
            facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: n)
        }
        generaPoligono(perFaccia: id)
        deselezionaTutto()
        mostraProxy = true; mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    // MARK: Flusso rapido — Tocca semi + Cresci tutti

    /// Lascia un seme sul triangolo toccato (un futuro piano). Istantaneo.
    func aggiungiSeme(triangolo i: Int, punto: SIMD3<Float>) {
        guard i >= 0, i < mesh.triangles.count else { return }
        semiTocco.append((i, punto))
        numSemi = semiTocco.count
        ridisegnaSemi()
    }

    /// Rimuove tutti i semi marcati (senza crescere).
    func annullaSemi() {
        semiTocco.removeAll(); numSemi = 0; ridisegnaSemi()
    }

    /// Fa crescere TUTTI i semi in una passata (adiacenza condivisa = veloce),
    /// creando un piano per ciascuno.
    func cresciTuttiSemi() {
        guard !semiTocco.isEmpty else { return }
        registraUndo()
        let adj = adiacenza()
        var ultimo: Int? = nil
        for s in semiTocco {
            if facce.contains(where: { $0.triangoli.contains(s.tri) }) { continue } // già coperto
            if let id = creaPianoDa(seme: [s.tri], adiacenza: adj) { ultimo = id }
        }
        facce.removeAll { $0.triangoli.isEmpty }
        stimaGravita()
        classificaPerGravita()
        for f in facce { generaPoligono(perFaccia: f.id) }
        if let id = ultimo { facciaAttivaId = id }
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        annullaSemi()
        strumento = .facce
        ridisegnaFacce(); ridisegnaPiani()
    }

    private func ridisegnaSemi() {
        semiNode.childNodes.forEach { $0.removeFromParentNode() }
        let r = CGFloat(estensioneMesh) * 0.012
        for s in semiTocco {
            let sf = SCNSphere(radius: r); sf.segmentCount = 12
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemYellow
            m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
            sf.materials = [m]
            let node = SCNNode(geometry: sf)
            node.position = SCNVector3(s.punto.x, s.punto.y, s.punto.z)
            semiNode.addChildNode(node)
        }
    }

    // MARK: Rileva perimetro — slice orizzontale → traccia → estrudi in facciate

    /// Entra in modalità perimetro: calcola lo slice e mette la vista dall'alto.
    /// Fase 1: posiziona la sezione sul 3D (slider quota). Fase 2: traccia il
    /// bordo nel pannello 2D.
    func avviaPerimetro() {
        modoPerimetro = true
        perimetroTraccia = false   // si parte posizionando la sezione sul 3D
        strumento = .orbita        // pan = orbita; la mesh resta visibile
        puntiPerimetro = []; numPuntiPerimetro = 0
        mostraMesh = true          // assicura la geometria visibile
        aggiornaSlice()
    }

    /// Passa alla fase di tracciamento (apre il pannello 2D).
    func iniziaTraccia() { perimetroTraccia = true; aggiornaSlice() }

    /// Esce dalla modalità perimetro: pulisce e riporta la vista in fronte (così la
    /// geometria è sempre visibile, mai "di taglio").
    func esciPerimetro() {
        modoPerimetro = false
        perimetroTraccia = false
        strumento = .orbita
        puntiPerimetro = []; numPuntiPerimetro = 0
        perimetroNode.childNodes.forEach { $0.removeFromParentNode() }
        mostraMesh = true
        // NESSUN cambio camera: resta dove l'hai lasciata → la mesh non sparisce.
    }

    /// Vista dall'alto on-demand per posizionare/vedere la sezione.
    func vistaDallAlto() { snapAlto() }

    /// Piano di slice corrente (punto, normale) — per il raycast dei tap.
    func pianoSlice() -> (p: SIMD3<Float>, n: SIMD3<Float>) {
        let su = simd_normalize(gravitaSu)
        return (su * sliceS0, su)
    }

    /// Ricalcola lo slice alla quota corrente e aggiorna pannello 2D + overlay 3D.
    func aggiornaSlice() {
        guard modoPerimetro else { return }
        let su = simd_normalize(gravitaSu)
        // base orizzontale stabile del piano di slice
        var e1 = simd_cross(su, SIMD3<Float>(0, 0, 1))
        if simd_length(e1) < 1e-4 { e1 = simd_cross(su, SIMD3<Float>(1, 0, 0)) }
        perimE1 = simd_normalize(e1); perimE2 = simd_normalize(simd_cross(su, perimE1))
        let (sMin, sMax) = mesh.rangeLungo(su)
        sliceS0 = sMin + max(0, min(1, quotaSlice)) * (sMax - sMin)
        let segs = mesh.sezione(quota: sliceS0, normale: su)
        ultimaSezione = segs
        ridisegnaPerimetro(segs)         // overlay 3D
        aggiornaDisegno2D(segs)          // pannello 2D
    }

    /// #2 — Trova automaticamente gli ANGOLI del profilo: concatena i segmenti
    /// della sezione in una polilinea ordinata, poi semplifica (Douglas-Peucker)
    /// → pochi punti sugli spigoli, già pronti per l'estrusione.
    func autoPerimetro() {
        let segs = ultimaSezione
        guard !segs.isEmpty else { return }
        let eps = max(estensioneMesh * 1e-3, 1e-6)
        let inv = 1.0 / eps
        func chiave(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x * inv).rounded()), Int32((p.y * inv).rounded()), Int32((p.z * inv).rounded()))
        }
        var nodeOf = [SIMD3<Int32>: Int](); var pos: [SIMD3<Float>] = []
        func nodeId(_ p: SIMD3<Float>) -> Int {
            let k = chiave(p)
            if let id = nodeOf[k] { return id }
            let id = pos.count; nodeOf[k] = id; pos.append(p); return id
        }
        var edges: [(Int, Int)] = []
        for (a, b) in segs { let ia = nodeId(a), ib = nodeId(b); if ia != ib { edges.append((ia, ib)) } }
        var incident = [[Int]](repeating: [], count: pos.count)
        for (ei, e) in edges.enumerated() { incident[e.0].append(ei); incident[e.1].append(ei) }
        // parti da un capo aperto (grado 1) se c'è, altrimenti dal nodo 0
        var start = 0
        for n in 0..<pos.count where incident[n].count == 1 { start = n; break }
        var usate = Set<Int>(); var path = [start]; var cur = start
        var prevDir: SIMD3<Float>? = nil
        while true {
            var best = -1; var bestScore: Float = -2
            for ei in incident[cur] where !usate.contains(ei) {
                let e = edges[ei]; let nxt = e.0 == cur ? e.1 : e.0
                let dir = simd_normalize(pos[nxt] - pos[cur])
                let score = prevDir == nil ? 1 : simd_dot(prevDir!, dir)
                if score > bestScore { bestScore = score; best = ei }
            }
            if best < 0 { break }
            usate.insert(best)
            let e = edges[best]; let nxt = e.0 == cur ? e.1 : e.0
            if nxt == start { break }
            prevDir = simd_normalize(pos[nxt] - pos[cur])
            path.append(nxt); cur = nxt
        }
        let pts3 = path.map { pos[$0] }
        let semplici = douglasPeucker(pts3, eps: estensioneMesh * 0.012)
        guard semplici.count >= 2 else { return }
        puntiPerimetro = semplici; numPuntiPerimetro = semplici.count
        aggiornaSlice()
    }

    private func douglasPeucker(_ pts: [SIMD3<Float>], eps: Float) -> [SIMD3<Float>] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        let ab = b - a; let len = simd_length(ab)
        var maxD: Float = 0; var idx = 0
        for i in 1..<(pts.count - 1) {
            let d = len < 1e-6 ? simd_length(pts[i] - a) : simd_length(simd_cross(pts[i] - a, ab)) / len
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > eps {
            let left = douglasPeucker(Array(pts[0...idx]), eps: eps)
            let right = douglasPeucker(Array(pts[idx...]), eps: eps)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }

    /// (u,v) nel piano di slice da un punto 3D, e viceversa.
    private func uv(_ p: SIMD3<Float>) -> CGPoint {
        CGPoint(x: CGFloat(simd_dot(p, perimE1)), y: CGFloat(simd_dot(p, perimE2)))
    }
    func mondoDaUV(_ p: CGPoint) -> SIMD3<Float> {
        simd_normalize(gravitaSu) * sliceS0 + perimE1 * Float(p.x) + perimE2 * Float(p.y)
    }

    /// Aggiunge un punto del perimetro dal pannello 2D (coord u,v).
    func toccaUV(_ p: CGPoint) { aggiungiPuntoPerimetro(mondoDaUV(p)) }

    private func aggiornaDisegno2D(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) {
        var d = PerimetroDisegno()
        d.segmenti = segs.map { (uv($0.0), uv($0.1)) }
        d.punti = puntiPerimetro.map { uv($0) }
        var traccia = puntiPerimetro
        if chiudiPerimetro, puntiPerimetro.count >= 3, let f = puntiPerimetro.first { traccia.append(f) }
        d.spline = traccia.map { uv($0) }   // linee rette tra i punti (campo riusato)
        // bounds (unione di tutti i punti)
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        func acc(_ q: CGPoint) { minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y) }
        for s in d.segmenti { acc(s.0); acc(s.1) }
        for q in d.punti { acc(q) }
        if maxX > minX, maxY > minY {
            d.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        disegnoPerimetro = d
    }

    /// Aggiunge un punto del perimetro (sul piano di slice).
    func aggiungiPuntoPerimetro(_ punto: SIMD3<Float>) {
        puntiPerimetro.append(punto); numPuntiPerimetro = puntiPerimetro.count
        aggiornaSlice()
    }

    func annullaUltimoPuntoPerimetro() {
        guard !puntiPerimetro.isEmpty else { return }
        puntiPerimetro.removeLast(); numPuntiPerimetro = puntiPerimetro.count
        aggiornaSlice()
    }

    /// Estrude il perimetro tracciato: ogni lato → un piano verticale di facciata
    /// (poligono che va dal fondo alla cima dell'edificio lungo la gravità).
    func estrudiPerimetro() {
        guard puntiPerimetro.count >= 2 else { return }
        registraUndo()
        let su = simd_normalize(gravitaSu)
        let (sMin, sMax) = mesh.rangeLungo(su)
        // un lato rettilineo per ogni coppia di punti consecutivi (+ chiusura opzionale)
        var lati: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<(puntiPerimetro.count - 1) { lati.append((puntiPerimetro[i], puntiPerimetro[i + 1])) }
        if chiudiPerimetro, puntiPerimetro.count >= 3, let a = puntiPerimetro.first, let b = puntiPerimetro.last {
            lati.append((b, a))
        }
        for (a, b) in lati {
            let aH = a - simd_dot(a, su) * su, bH = b - simd_dot(b, su) * su   // parte orizzontale
            var nrm = simd_cross(b - a, su)
            if simd_length(nrm) < 1e-5 { continue }
            nrm = simd_normalize(nrm)
            let la = aH + su * sMin, lb = bH + su * sMin
            let hb = bH + su * sMax, ha = aH + su * sMax
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            var f = FacciaProxy(id: prossimoIdFaccia, nome: "Facciata \(prossimoIdFaccia)", colore: colore)
            prossimoIdFaccia += 1
            f.poligono = [la, lb, hb, ha]
            f.pianoNormale = nrm
            f.pianoPunto = (la + lb + hb + ha) * 0.25
            f.tipo = .facciata
            facce.append(f)
            fittaPianoAllaMesh(f.id)   // segui il muro reale (anche inclinato)
        }
        esciPerimetro()
        pianiGenerati = facce.count
        mostraPiani = true
        facciaAttivaId = facce.last?.id
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Fitta il piano (poligono) alla MESH reale: raccoglie i triangoli vicini al
    /// piano e allineati, ne fa il fit RANSAC e ri-proietta il poligono sul piano
    /// fittato. Così, se il muro è inclinato, il piano lo segue.
    func fittaPianoAllaMesh(_ id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              var poly = facce[i].poligono, let n0 = facce[i].pianoNormale,
              let p0 = facce[i].pianoPunto else { return }
        let n = simd_normalize(n0)
        let banda = estensioneMesh * 0.06
        let cosN = cos(35 * Float.pi / 180)
        // estensione orizzontale del poligono (per non prendere muri lontani)
        let su = simd_normalize(gravitaSu)
        var asseOr = simd_cross(su, n)
        if simd_length(asseOr) < 1e-5 { asseOr = simd_cross(SIMD3(1, 0, 0), n) }
        asseOr = simd_normalize(asseOr)
        let proj = poly.map { simd_dot($0 - p0, asseOr) }
        let oMin = (proj.min() ?? 0) - banda, oMax = (proj.max() ?? 0) + banda
        var vicini = Set<Int>()
        for t in mesh.triangles.indices {
            let c = mesh.centroid(mesh.triangles[t])
            guard abs(simd_dot(c - p0, n)) < banda, abs(simd_dot(mesh.normale(t), n)) > cosN else { continue }
            let o = simd_dot(c - p0, asseOr)
            if o >= oMin, o <= oMax { vicini.insert(t) }
        }
        guard vicini.count >= 20, let (p2, n2v) = mesh.fitPianoRANSAC(vicini) else { return }
        var n2 = simd_normalize(n2v)
        if simd_dot(n2, n) < 0 { n2 = -n2 }
        for k in poly.indices { poly[k] = poly[k] - simd_dot(poly[k] - p2, n2) * n2 }   // sul piano fittato
        facce[i].poligono = poly
        facce[i].pianoNormale = n2
        facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0, 0, 0), +) / Float(poly.count)
        facce[i].triangoli = vicini
        facce[i].erroreRms = mesh.rmsDalPiano(vicini, punto: p2, normale: n2)
        ridisegnaPiani()
    }

    /// Spline Catmull-Rom passante per i punti di controllo (chiusa se ≥3 punti):
    /// "ricalca" il profilo con una curva morbida.
    private func splinePunti(perSeg: Int = 12) -> [SIMD3<Float>] {
        let p = puntiPerimetro
        guard p.count >= 3 else { return p }
        let n = p.count
        func cr(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            let t2 = t * t, t3 = t2 * t
            let a: SIMD3<Float> = 2 * p1
            let b: SIMD3<Float> = (p2 - p0) * t
            let c0: SIMD3<Float> = 2 * p0 - 5 * p1 + 4 * p2 - p3
            let c: SIMD3<Float> = c0 * t2
            let d0: SIMD3<Float> = 3 * p1 - 3 * p2 + p3 - p0
            let d: SIMD3<Float> = d0 * t3
            return (a + b + c + d) * 0.5
        }
        var out: [SIMD3<Float>] = []
        for i in 0..<n {   // chiusa
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            for s in 0..<perSeg { out.append(cr(p0, p1, p2, p3, Float(s) / Float(perSeg))) }
        }
        out.append(p[0])
        return out
    }

    /// Semplifica una polilinea in segmenti rettilinei: spezza dove la direzione
    /// cambia oltre `tolGradi` (muri dritti → 1 segmento, curve → più segmenti).
    private func semplificaSegmenti(_ pts: [SIMD3<Float>], tolGradi: Float = 12) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard pts.count >= 2 else { return [] }
        let cosT = cos(tolGradi * .pi / 180)
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var inizio = pts[0]
        var dirRif: SIMD3<Float>? = nil
        for i in 1..<pts.count {
            let d = pts[i] - pts[i - 1]
            if simd_length(d) < 1e-6 { continue }
            let dir = simd_normalize(d)
            if let r = dirRif, simd_dot(r, dir) < cosT {
                segs.append((inizio, pts[i - 1])); inizio = pts[i - 1]; dirRif = dir
            } else if dirRif == nil { dirRif = dir }
        }
        segs.append((inizio, pts.last!))
        return segs
    }

    private func geometriaSegmenti(_ segs: [(SIMD3<Float>, SIMD3<Float>)], colore: UIColor) -> SCNGeometry? {
        guard !segs.isEmpty else { return nil }
        var verts: [SCNVector3] = []; var idx: [Int32] = []
        for (a, b) in segs {
            let i = Int32(verts.count)
            verts.append(SCNVector3(a.x, a.y, a.z)); verts.append(SCNVector3(b.x, b.y, b.z))
            idx += [i, i + 1]
        }
        let src = SCNGeometrySource(vertices: verts)
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial(); m.diffuse.contents = colore; m.lightingModel = .constant
        m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        g.materials = [m]
        return g
    }

    private func ridisegnaPerimetro(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) {
        perimetroNode.childNodes.forEach { $0.removeFromParentNode() }
        // Piano di sezione TRASLUCIDO sul 3D (fase 1: posizionamento): un quad
        // orizzontale alla quota corrente, esteso sul footprint della mesh.
        let su = simd_normalize(gravitaSu)
        let (lo, hi) = mesh.aabb
        var uMin = Float.greatestFiniteMagnitude, uMax = -uMin, vMin = uMin, vMax = -uMin
        for cx in [lo.x, hi.x] { for cy in [lo.y, hi.y] { for cz in [lo.z, hi.z] {
            let p = SIMD3<Float>(cx, cy, cz)
            let u = simd_dot(p, perimE1), w = simd_dot(p, perimE2)
            uMin = min(uMin, u); uMax = max(uMax, u); vMin = min(vMin, w); vMax = max(vMax, w)
        }}}
        if uMax > uMin {
            let base = su * sliceS0
            let q = [base + perimE1 * uMin + perimE2 * vMin, base + perimE1 * uMax + perimE2 * vMin,
                     base + perimE1 * uMax + perimE2 * vMax, base + perimE1 * uMin + perimE2 * vMax]
                .map { SCNVector3($0.x, $0.y, $0.z) }
            let src = SCNGeometrySource(vertices: q)
            let el = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 0, 2, 3), primitiveType: .triangles)
            let g = SCNGeometry(sources: [src], elements: [el])
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
            m.isDoubleSided = true; m.lightingModel = .constant; m.writesToDepthBuffer = false
            g.materials = [m]
            perimetroNode.addChildNode(SCNNode(geometry: g))
        }
        // contorno della sezione (ciano acceso) = guida da ricalcare: linee + pallini
        if let g = geometriaSegmenti(segs, colore: UIColor.systemTeal) {
            perimetroNode.addChildNode(SCNNode(geometry: g))
        }
        if !segs.isEmpty {
            let rp = CGFloat(estensioneMesh) * 0.006
            let passo = max(1, segs.count / 160)   // ~160 pallini max
            var k = 0
            while k < segs.count {
                let m = (segs[k].0 + segs[k].1) * 0.5
                let s = SCNSphere(radius: rp); s.segmentCount = 8
                let mat = SCNMaterial(); mat.diffuse.contents = UIColor.systemTeal
                mat.lightingModel = .constant; mat.readsFromDepthBuffer = false; mat.writesToDepthBuffer = false
                s.materials = [mat]
                let node = SCNNode(geometry: s); node.position = SCNVector3(m.x, m.y, m.z)
                perimetroNode.addChildNode(node)
                k += passo
            }
        }
        // traccia dell'utente a linee RETTE (giallo) + punti di controllo
        var traccia = puntiPerimetro
        if chiudiPerimetro, puntiPerimetro.count >= 3, let f = puntiPerimetro.first { traccia.append(f) }
        if traccia.count >= 2 {
            var ts: [(SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<(traccia.count - 1) { ts.append((traccia[i], traccia[i + 1])) }
            if let g = geometriaSegmenti(ts, colore: .systemYellow) {
                perimetroNode.addChildNode(SCNNode(geometry: g))
            }
        }
        let r = CGFloat(estensioneMesh) * 0.014
        for p in puntiPerimetro {
            let s = SCNSphere(radius: r); s.segmentCount = 12
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemYellow
            m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
            s.materials = [m]
            let node = SCNNode(geometry: s)
            node.position = SCNVector3(p.x, p.y, p.z)
            perimetroNode.addChildNode(node)
        }
    }

    /// Genera i piani da ciò che hai marcato: ogni SEME (tocco) è un piano a sé;
    /// una SELEZIONE (pennello/rettangolo/lazo) fa UN solo piano (cresce da tutto
    /// il segno, non lo spezza). Più piani = più semi, o più selezioni separate.
    func generaDaMarcatura() {
        if numSemi > 0 { cresciTuttiSemi() }
        else if !selezione.isEmpty { cresciDaSelezione(split: false) }
    }

    /// Azzera la marcatura corrente (semi + selezione) senza generare.
    func annullaMarcatura() { annullaSemi(); deselezionaTutto() }

    /// Rende attivo un piano e ridisegna (per mostrarne le maniglie).
    func selezionaFacciaAttiva(_ id: Int) {
        facciaAttivaId = id
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Usa la selezione come seme. `split=false` → un solo piano da tutta la
    /// selezione (più zone unite in un piano). `split=true` → un piano per ogni
    /// zona connessa della selezione (più zone → più piani).
    func cresciDaSelezione(split: Bool = false) {
        guard !selezione.isEmpty else { return }
        registraUndo()
        let semi = split ? mesh.componentiConnesse(selezione) : [selezione]
        let adj = adiacenza()
        var ultimo: Int? = nil
        for seme in semi { if let id = creaPianoDa(seme: seme, adiacenza: adj) { ultimo = id } }
        facce.removeAll { $0.triangoli.isEmpty }
        stimaGravita()
        classificaPerGravita()
        for f in facce { generaPoligono(perFaccia: f.id) }
        if let id = ultimo { facciaAttivaId = id }
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        deselezionaTutto()
        strumento = .facce
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// #12 + #13 — Snap "Manhattan": costruisce una terna ortogonale dall'edificio
    /// (su = gravità, asse1 = normale della facciata maggiore, asse2 = su×asse1) e
    /// aggancia ogni piano all'asse più vicino. CONSERVATIVO: snappa solo se già
    /// entro 12° (non forza muri genuinamente obliqui). Effetto: i ritorni diventano
    /// esattamente ⟂ alla facciata (#12) e tutti i muri ⟂/∥ tra loro (#13).
    private func snapManhattan() {
        let su = gravitaSu
        var axis1: SIMD3<Float>? = nil; var areaMax: Float = 0
        for f in facce {
            guard let n = f.pianoNormale else { continue }
            let horiz = n - simd_dot(n, su) * su           // componente orizzontale
            if simd_length(horiz) < 0.3 { continue }       // orizzontale → salta
            let a = mesh.areaTriangoli(f.triangoli)
            if a > areaMax { areaMax = a; axis1 = simd_normalize(horiz) }
        }
        guard let a1 = axis1 else { return }
        let a2 = simd_normalize(simd_cross(su, a1))
        let cand = [a1, -a1, a2, -a2, su, -su]
        let cos12 = cos(12 * Float.pi / 180)
        for i in facce.indices {
            guard let n = facce[i].pianoNormale else { continue }
            if let best = cand.max(by: { simd_dot(n, $0) < simd_dot(n, $1) }),
               simd_dot(n, best) > cos12 {
                aggiornaNormaleFaccia(facce[i].id, best)
            }
        }
    }

    /// Crea una nuova faccia (colore successivo della palette) e la rende attiva.
    func nuovaFaccia() {
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        let f = FacciaProxy(id: prossimoIdFaccia, nome: "Faccia \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        facce.append(f)
        facciaAttivaId = f.id
    }

    // MARK: Crescita dal pennello + punto zero (§3, brush-seeded)

    /// In attesa che l'utente tocchi il muro per fissare il punto zero.
    @Published var attendePuntoZero = false

    /// Espande la faccia attiva dal pennellato al MURO (region growing per
    /// normale+profondità): un segno piccolo cattura tutta la facciata.
    func espandiAlPiano() {
        guard let id = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == id }),
              !facce[i].triangoli.isEmpty,
              let (p, n) = mesh.fitPianoRANSAC(facce[i].triangoli) else { return }
        registraUndo()
        let cresciuto = mesh.crescePianare(da: facce[i].triangoli, normale: n, punto: p,
                                           tolGradi: Float(tolleranzaNormaleGradi), adiacenza: adiacenza())
        for j in facce.indices where j != i { facce[j].triangoli.subtract(cresciuto) }
        facce[i].triangoli = cresciuto
        if let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) {
            facce[i].pianoPunto = p2; facce[i].pianoNormale = n2
            facce[i].erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
        }
        mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Tocco→piano: l'utente tocca una superficie e nasce LÌ un nuovo piano,
    /// cresciuto per region-growing dal triangolo colpito. Deterministico
    /// (niente RANSAC casuale) e scelto dall'utente: marca i piani che vuoi.
    func toccaPerPiano(triangolo i: Int) {
        guard i >= 0, i < mesh.triangles.count else { return }
        // Tocchi un piano GIÀ riconosciuto → lo SELEZIONI (non ne crei un altro).
        if let g = facce.first(where: { $0.triangoli.contains(i) }) {
            facciaAttivaId = g.id
            ridisegnaFacce(); ridisegnaPiani()
            return
        }
        registraUndo()
        let p = mesh.centroid(mesh.triangles[i])
        let n = mesh.normale(i)
        let cresciuto = mesh.crescePianare(da: [i], normale: n, punto: p,
                                           tolGradi: Float(tolleranzaNormaleGradi), adiacenza: adiacenza())
        // non rubare triangoli a piani già marcati
        for j in facce.indices { facce[j].triangoli.subtract(cresciuto) }
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia,
                            nome: "Piano \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.triangoli = cresciuto
        if let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) {
            f.pianoPunto = p2; f.pianoNormale = n2
            f.erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
            f.tipo = abs(n2.y) > 0.7 ? .orizzontale : .facciata
        } else {
            f.pianoPunto = p; f.pianoNormale = n
        }
        facce.append(f)
        facciaAttivaId = f.id
        facce.removeAll { $0.triangoli.isEmpty }
        generaPoligono(perFaccia: f.id)
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Avvia/annulla la modalità "tocca il muro per il punto zero".
    func attivaPuntoZero() { attendePuntoZero.toggle() }

    /// Fissa il punto zero della faccia attiva sul punto toccato del muro:
    /// il piano mantiene l'ORIENTAMENTO ma viene ancorato lì (finestre/balconi
    /// restano fuori e si appiattiscono sul piano).
    func impostaPuntoZero(_ world: SCNVector3) {
        attendePuntoZero = false
        guard let id = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == id }) else { return }
        registraUndo()
        let p = SIMD3<Float>(world.x, world.y, world.z)
        // Normale: quella già fittata, o ricavata dai triangoli, o dal piano base.
        let n = simd_normalize(facce[i].pianoNormale
            ?? mesh.fitPiano(facce[i].triangoli)?.normale
            ?? (haPianoBase ? pianoBaseNormale : SIMD3<Float>(0, 0, 1)))
        facce[i].pianoNormale = n
        // Ancora il piano al punto toccato lungo la normale (mantiene orientamento e
        // forma): per i piani solo-poligono trasla il poligono, altrimenti sposta il punto.
        if var poly = facce[i].poligono, !poly.isEmpty {
            let c = poly.reduce(SIMD3<Float>(0, 0, 0), +) / Float(poly.count)
            let off = simd_dot(p - c, n)
            for k in poly.indices { poly[k] += n * off }
            facce[i].poligono = poly
            facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0, 0, 0), +) / Float(poly.count)
        } else {
            facce[i].pianoPunto = p
        }
        facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: facce[i].pianoPunto ?? p, normale: n)
        mostraPiani = true
        ridisegnaPiani()
    }

    /// Assegna i triangoli pennellati alla faccia attiva (e li toglie dalle altre).
    func assegnaAFacciaAttiva(_ idx: Set<Int>) {
        guard let fid = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == fid }) else { return }
        var cambiato = false
        for j in facce.indices where j != i {
            let prima = facce[j].triangoli.count
            facce[j].triangoli.subtract(idx)
            if facce[j].triangoli.count != prima { cambiato = true }
        }
        let prima = facce[i].triangoli.count
        facce[i].triangoli.formUnion(idx)
        if facce[i].triangoli.count != prima { cambiato = true }
        if cambiato { ridisegnaFacce() }
    }

    func rinominaFaccia(_ id: Int, _ nome: String) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].nome = nome
    }

    func cambiaTipoFaccia(_ id: Int, _ tipo: TipoFaccia) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].tipo = tipo
    }

    func cambiaPrioritaFaccia(_ id: Int, _ priorita: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].priorita = max(0, priorita)
    }

    func eliminaFaccia(_ id: Int) {
        facce.removeAll { $0.id == id }
        if facciaAttivaId == id { facciaAttivaId = facce.last?.id }
        ridisegnaFacce()
    }

    /// Unisce la faccia `sorgente` in `target` (ne assorbe i triangoli) e la rimuove.
    func unisciFacce(target: Int, sorgente: Int) {
        guard target != sorgente,
              let ti = facce.firstIndex(where: { $0.id == target }),
              let si = facce.firstIndex(where: { $0.id == sorgente }) else { return }
        facce[ti].triangoli.formUnion(facce[si].triangoli)
        facce[ti].pianoPunto = nil; facce[ti].pianoNormale = nil; facce[ti].erroreRms = nil
        facce.remove(at: si)
        if facciaAttivaId == sorgente { facciaAttivaId = target }
        ridisegnaFacce()
    }

    /// Genera (fit) il piano di ogni faccia dai triangoli pennellati + errore RMS.
    func generaPiani() {
        var n = 0
        for i in facce.indices {
            if let (p, nrm) = mesh.fitPiano(facce[i].triangoli) {
                facce[i].pianoPunto = p; facce[i].pianoNormale = nrm
                facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: nrm)
                n += 1
            }
        }
        pianiGenerati = n
        mostraPiani = true
        ridisegnaPiani()
    }

    /// Fitta solo le facce ancora senza piano (preserva squadratura/offset manuali).
    private func assicuraPiani() {
        for i in facce.indices where facce[i].pianoNormale == nil {
            if let (p, nrm) = mesh.fitPiano(facce[i].triangoli) {
                facce[i].pianoPunto = p; facce[i].pianoNormale = nrm
                facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: nrm)
            }
        }
    }

    // MARK: Rifinitura piani — squadratura/snap/offset (§6 a livello proxy)

    /// Assi di riferimento: del piano base se c'è, altrimenti assi mondo.
    private var assiRif: (r: SIMD3<Float>, u: SIMD3<Float>, n: SIMD3<Float>) {
        haPianoBase ? (pianoBaseRight, pianoBaseUp, pianoBaseNormale)
                    : (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
    }

    private func aggiornaNormaleFaccia(_ id: Int, _ nuova: SIMD3<Float>) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto else { return }
        let n = simd_normalize(nuova)
        facce[i].pianoNormale = n
        facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: n)
        ridisegnaPiani()
    }

    /// Squadra: aggancia la normale all'asse di riferimento più vicino.
    func squadraPiano(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let a = assiRif
        let cand = [a.r, -a.r, a.u, -a.u, a.n, -a.n]
        let best = cand.max(by: { simd_dot(n, $0) < simd_dot(n, $1) }) ?? n
        aggiornaNormaleFaccia(id, best)
    }

    /// Faccia verticale: normale orizzontale (⟂ all'asse "up").
    func pianoVerticale(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let u = assiRif.u
        let proj = n - simd_dot(n, u) * u
        if simd_length(proj) > 1e-4 { aggiornaNormaleFaccia(id, proj) }
    }

    /// Faccia orizzontale (davanzale/cornicione): normale = asse "up".
    func pianoOrizzontale(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let u = assiRif.u
        aggiornaNormaleFaccia(id, simd_dot(n, u) >= 0 ? u : -u)
    }

    /// Offset del piano lungo la sua normale (rientro/rilievo), step = ‰ del lato.
    func offsetPiano(_ id: Int, verso: Float) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto, let n = facce[i].pianoNormale else { return }
        facce[i].pianoPunto = p + n * (estensioneMesh * 0.005 * verso)
        ridisegnaPiani()
    }

    /// Regola l'altezza del poligono: sposta la CIMA (cima=true) o la BASE
    /// (cima=false) lungo la gravità → alza/abbassa il bordo alto/basso delle facciate.
    func regolaAltezzaFaccia(_ id: Int, cima: Bool, verso: Float) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              var poly = facce[i].poligono, poly.count >= 3 else { return }
        let su = simd_normalize(gravitaSu)
        let proj = poly.map { simd_dot($0, su) }
        guard let lo = proj.min(), let hi = proj.max(), hi > lo else { return }
        let mid = (lo + hi) * 0.5
        let step = su * (estensioneMesh * 0.02 * verso)
        registraUndo()
        for k in poly.indices where (proj[k] >= mid) == cima { poly[k] += step }
        facce[i].poligono = poly
        facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0, 0, 0), +) / Float(poly.count)
        ridisegnaPiani()
    }

    /// Quad colorato per ogni piano fittato (anteprima multipiano proxy).
    private func ridisegnaPiani() {
        pianiNode.childNodes.forEach { $0.removeFromParentNode() }
        pianiNode.isHidden = !mostraPiani
        guard mostraPiani else { return }
        let upRef = assiRif.u
        for f in facce {
            guard let n = f.pianoNormale else { continue }
            // Poligono editabile se presente (anche per facciate estruse senza
            // triangoli); altrimenti bbox del piano dai triangoli pennellati.
            let pts3: [SIMD3<Float>]
            if let poly = f.poligono, poly.count >= 3 {
                pts3 = poly
            } else if let o = f.pianoPunto, !f.triangoli.isEmpty {
                var right = simd_cross(upRef, n)
                if simd_length(right) < 1e-4 { right = simd_cross(SIMD3(1, 0, 0), n) }
                right = simd_normalize(right)
                let up = simd_normalize(simd_cross(n, right))
                var uMin = Float.greatestFiniteMagnitude, uMax = -Float.greatestFiniteMagnitude
                var wMin = Float.greatestFiniteMagnitude, wMax = -Float.greatestFiniteMagnitude
                for ti in f.triangoli {
                    let t = mesh.triangles[ti]
                    for v in [mesh.vertices[Int(t.x)], mesh.vertices[Int(t.y)], mesh.vertices[Int(t.z)]] {
                        let d = v - o
                        let u = simd_dot(d, right), w = simd_dot(d, up)
                        uMin = min(uMin, u); uMax = max(uMax, u); wMin = min(wMin, w); wMax = max(wMax, w)
                    }
                }
                guard uMax > uMin else { continue }
                pts3 = [o + right * uMin + up * wMin, o + right * uMax + up * wMin,
                        o + right * uMax + up * wMax, o + right * uMin + up * wMax]
            } else { continue }
            let corners = pts3.map { SCNVector3($0.x, $0.y, $0.z) }
            // riempimento a ventaglio (poligoni convessi)
            var idx: [Int32] = []
            for k in 1..<(corners.count - 1) { idx += [0, Int32(k), Int32(k + 1)] }
            let src = SCNGeometrySource(vertices: corners)
            let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
            let g = SCNGeometry(sources: [src], elements: [elem])
            // Pieno & opaco quando si guardano SOLO i piani (geometria/texture nascoste),
            // così il piano si legge come una superficie solida; semi-trasparente quando
            // è sovrapposto alla mesh (per non coprirla). Con i piani pieni si scrive sul
            // depth → si occludono correttamente fra loro.
            let soloPiani = !mostraMesh && !mostraTexturaOC
            let m = SCNMaterial()
            m.diffuse.contents = f.colore.withAlphaComponent(soloPiani ? 1.0 : 0.45)
            m.isDoubleSided = true; m.lightingModel = .constant
            m.writesToDepthBuffer = soloPiani
            g.materials = [m]
            let fill = SCNNode(geometry: g)
            fill.name = "piano:\(f.id)"   // selezionabile col tap (anche piani solo-poligono)
            pianiNode.addChildNode(fill)
            if let c = MeshFactory.lineaGeometria(corners, colore: f.colore, chiusa: true) {
                pianiNode.addChildNode(SCNNode(geometry: c))
            }
            // Maniglie (solo sul poligono editabile della faccia attiva):
            // sfere bianche = angoli (Fase C drag), cubetti arancioni = edge
            // (trascina lato / tocca per splittare).
            if f.poligono != nil, f.id == facciaAttivaId {
                let r = CGFloat(estensioneMesh) * 0.012
                for (k, c) in corners.enumerated() {
                    let s = SCNSphere(radius: r); s.segmentCount = 12
                    let sm = SCNMaterial(); sm.diffuse.contents = UIColor.white
                    sm.lightingModel = .constant; sm.writesToDepthBuffer = false
                    s.materials = [sm]
                    let node = SCNNode(geometry: s)
                    node.position = c
                    node.name = "maniglia:\(f.id):\(k)"
                    pianiNode.addChildNode(node)
                }
                for k in corners.indices {
                    let a = pts3[k], b = pts3[(k + 1) % pts3.count]
                    let mid = (a + b) * 0.5
                    let box = SCNBox(width: r * 1.5, height: r * 1.5, length: r * 1.5, chamferRadius: 0)
                    let bm = SCNMaterial(); bm.diffuse.contents = UIColor.orange
                    bm.lightingModel = .constant; bm.writesToDepthBuffer = false
                    box.materials = [bm]
                    let node = SCNNode(geometry: box)
                    node.position = SCNVector3(mid.x, mid.y, mid.z)
                    node.name = "edge:\(f.id):\(k)"
                    pianiNode.addChildNode(node)
                }
            }
        }
    }

    // MARK: Validazione (§8)

    private func mostraFaccia(_ f: FacciaProxy) -> Bool {
        switch vistaValidazione {
        case .normale, .soloProxy: return true
        case .soloAccettate:       return f.tipo != .scarto
        case .soloScarti:          return f.tipo == .scarto
        }
    }

    /// Applica la vista corrente: trasparenza mesh + visibilità overlay proxy +
    /// mostra/nascondi la geometria OC grigia e la versione texturizzata OC.
    private func aggiornaVista() {
        let t: CGFloat = vistaValidazione == .soloProxy ? 0.04
            : (vistaValidazione == .soloScarti ? 0.18 : 1.0)
        // geometria grigia nascosta se l'utente la spegne o se mostra la texture
        let mostraGrigia = mostraMesh && !mostraTexturaOC
        contentNode.geometry?.firstMaterial?.transparency = mostraGrigia ? t : 0
        ocTextureNode?.isHidden = !mostraTexturaOC
        facceProxyNode.isHidden = !mostraProxy
        ridisegnaFacce()
        ridisegnaPiani()   // i piani diventano pieni/trasparenti secondo la visibilità mesh
    }

    /// Riallinea gli insiemi di triangoli delle facce dopo un taglio (remap).
    private func rimappaFacce(_ remap: [Int]) {
        guard !facce.isEmpty else { return }
        for i in facce.indices {
            facce[i].triangoli = Set(facce[i].triangoli.compactMap { remap.indices.contains($0) && remap[$0] >= 0 ? remap[$0] : nil })
            facce[i].pianoPunto = nil; facce[i].pianoNormale = nil   // il fit va rifatto
        }
        facce.removeAll { $0.triangoli.isEmpty }
        if facciaAttivaId == nil || !facce.contains(where: { $0.id == facciaAttivaId }) {
            facciaAttivaId = facce.last?.id
        }
        ridisegnaFacce()
    }

    /// Ricostruisce l'overlay colorato delle facce (una geometria per faccia).
    private func ridisegnaFacce() {
        facceProxyNode.childNodes.forEach { $0.removeFromParentNode() }
        for f in facce where mostraFaccia(f) {
            guard let g = mesh.selezioneGeometry(f.triangoli, colore: f.colore.withAlphaComponent(0.6)) else { continue }
            facceProxyNode.addChildNode(SCNNode(geometry: g))
        }
    }

    // MARK: Esportazione proxy (§9)

    @Published var statoProxy: StatoProxy = .corretto

    /// Scrive `proxy_overrides.json` (override manuali completi, triangoli inclusi)
    /// e `multipiano_proxy.json` (solo piani per il bake) in temp; ritorna gli URL.
    func esportaProxy(nomeBase: String) -> [URL] {
        assicuraPiani()   // fitta SOLO i piani mancanti (non tocca le rifiniture)
        let pb: PianoBaseJSON? = haPianoBase ? PianoBaseJSON(
            origine: pianoBaseOrigine.lista, normale: pianoBaseNormale.lista,
            right: pianoBaseRight.lista, up: pianoBaseUp.lista) : nil

        let overrides = ProxyOverridesJSON(
            versione: 1, stato: statoProxy.raw,
            mesh: MeshInfoJSON(vertici: mesh.vertexCount, triangoli: mesh.triangleCount),
            piano_base: pb,
            facce: facce.map { f in
                FacciaOverrideJSON(
                    id: f.id, nome: f.nome, tipo: f.tipo.rawValue, colore: f.coloreHex,
                    priorita: f.priorita, n_triangoli: f.triangoli.count,
                    triangoli: f.triangoli.sorted(),
                    piano: f.pianoPunto.flatMap { p in f.pianoNormale.map {
                        PianoJSON(punto: p.lista, normale: $0.lista) } })
            })

        let multipiano = MultipianoJSON(
            versione: 1, stato: statoProxy.raw, piano_base: pb,
            piani: facce.compactMap { f in
                guard let p = f.pianoPunto, let n = f.pianoNormale else { return nil }
                return PianoProxyJSON(id: f.id, nome: f.nome, tipo: f.tipo.rawValue,
                                      priorita: f.priorita, punto: p.lista, normale: n.lista)
            })

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var urls: [URL] = []
        let dir = FileManager.default.temporaryDirectory
        if let d = try? enc.encode(overrides) {
            let u = dir.appendingPathComponent("\(nomeBase)_proxy_overrides.json")
            if (try? d.write(to: u, options: .atomic)) != nil { urls.append(u) }
        }
        if let d = try? enc.encode(multipiano) {
            let u = dir.appendingPathComponent("\(nomeBase)_multipiano_proxy.json")
            if (try? d.write(to: u, options: .atomic)) != nil { urls.append(u) }
        }
        return urls
    }

    // MARK: Creazione faccia per punti (Fase 2)

    /// Aggiunge un vertice della faccia in costruzione (punto sulla superficie
    /// della mesh, già in world space dall'hit-test). Chiamato dal tap.
    func aggiungiPunto(_ p: SCNVector3) {
        guard strumento == .punti else { return }
        puntiFaccia.append(p)
        numPuntiFaccia = puntiFaccia.count
        ridisegnaPunti()
    }

    func rimuoviUltimoPunto() {
        guard !puntiFaccia.isEmpty else { return }
        puntiFaccia.removeLast()
        numPuntiFaccia = puntiFaccia.count
        ridisegnaPunti()
    }

    func annullaFaccia() {
        puntiFaccia.removeAll()
        numPuntiFaccia = 0
        ridisegnaPunti()
    }

    /// §4 — Calcola il piano livello-zero dai punti toccati (≥3): fit PCA →
    /// origine (centroide) + normale + assi nel piano, e lo visualizza.
    func calcolaPianoBase() {
        guard puntiFaccia.count >= 3 else { return }
        let pts = puntiFaccia.map { SIMD3<Float>($0.x, $0.y, $0.z) }
        var mean = SIMD3<Double>(repeating: 0)
        for p in pts { mean += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        mean /= Double(pts.count)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pts {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - mean
            cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
            cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z; cov[2][2] += d.z * d.z
        }
        cov[1][0] = cov[0][1]; cov[2][0] = cov[0][2]; cov[2][1] = cov[1][2]
        let (_, vecs) = EditableMesh.eigenSym3(cov)
        let n = simd_normalize(SIMD3<Float>(Float(vecs[0][2]), Float(vecs[1][2]), Float(vecs[2][2])))

        pianoBaseOrigine = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
        pianoBaseNormale = n
        // Assi nel piano: right ⟂ n usando un riferimento non parallelo.
        let rif: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        pianoBaseRight = simd_normalize(simd_cross(rif, n))
        pianoBaseUp = simd_normalize(simd_cross(n, pianoBaseRight))
        haPianoBase = true
        renderPianoBase()
        annullaFaccia()
    }

    private func renderPianoBase() {
        pianoBaseNode.childNodes.forEach { $0.removeFromParentNode() }
        pianoBaseNode.geometry = nil
        guard haPianoBase else { return }
        let hs = max(estensioneMesh * 0.6, 0.5)
        let o = pianoBaseOrigine
        let r = pianoBaseRight * hs, u = pianoBaseUp * hs
        let corners = [o - r - u, o + r - u, o + r + u, o - r + u].map { SCNVector3($0.x, $0.y, $0.z) }
        let src = SCNGeometrySource(vertices: corners)
        let elem = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 0, 2, 3), primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(EditorTheme.accento).withAlphaComponent(0.22)
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        g.materials = [m]
        pianoBaseNode.geometry = g
        // Contorno del piano.
        if let c = MeshFactory.lineaGeometria(corners, colore: UIColor(EditorTheme.accento), chiusa: true) {
            pianoBaseNode.addChildNode(SCNNode(geometry: c))
        }
    }

    /// Allinea il box di lavoro al piano livello-zero (asse z = normale).
    func allineaBoxAlPianoBase() {
        guard haPianoBase else { return }
        boxRot = simd_float3x3(pianoBaseRight, pianoBaseUp, pianoBaseNormale)
        frameOrigin = pianoBaseOrigine
        let rt = boxRot.transpose
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices { let l = rt * (v - frameOrigin); lo = simd_min(lo, l); hi = simd_max(hi, l) }
        let margine = (hi - lo) * 0.02
        boxLo = lo - margine; boxHi = hi + margine
        ricostruisciBox()
    }

    /// Ricostruisce sfere + polilinea dei punti in corso.
    private func ridisegnaPunti() {
        markersNode.childNodes
            .filter { $0 !== lineNode }
            .forEach { $0.removeFromParentNode() }
        for p in puntiFaccia {
            let s = SCNNode(geometry: SCNSphere(radius: raggioMarker))
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(EditorTheme.accento)
            m.lightingModel = .constant
            s.geometry?.materials = [m]
            s.position = p
            markersNode.addChildNode(s)
        }
        lineNode.geometry = MeshFactory.lineaGeometria(
            puntiFaccia, colore: UIColor(EditorTheme.accento), chiusa: false)
    }
}

// MARK: – Fabbrica mesh procedurale (test bed editabile)

enum MeshFactory {
    /// Polilinea (aperta o chiusa) che collega i punti — contorno della faccia.
    static func lineaGeometria(_ pts: [SCNVector3], colore: UIColor,
                               chiusa: Bool) -> SCNGeometry? {
        guard pts.count >= 2 else { return nil }
        var indici: [Int32] = []
        for i in 0..<(pts.count - 1) { indici += [Int32(i), Int32(i + 1)] }
        if chiusa, pts.count >= 3 { indici += [Int32(pts.count - 1), 0] }
        let src = SCNGeometrySource(vertices: pts)
        let elem = SCNGeometryElement(indices: indici, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        g.materials = [m]
        return g
    }

    /// Wireframe (12 spigoli) di un box assi-allineato lo..hi.
    static func boxWireframe(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>,
                             colore: UIColor) -> SCNGeometry {
        let c: [SCNVector3] = [
            SCNVector3(lo.x, lo.y, lo.z), SCNVector3(hi.x, lo.y, lo.z),
            SCNVector3(hi.x, hi.y, lo.z), SCNVector3(lo.x, hi.y, lo.z),
            SCNVector3(lo.x, lo.y, hi.z), SCNVector3(hi.x, lo.y, hi.z),
            SCNVector3(hi.x, hi.y, hi.z), SCNVector3(lo.x, hi.y, hi.z),
        ]
        let e: [Int32] = [0,1, 1,2, 2,3, 3,0,  4,5, 5,6, 6,7, 7,4,  0,4, 1,5, 2,6, 3,7]
        let src = SCNGeometrySource(vertices: c)
        let elem = SCNGeometryElement(indices: e, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // il box resta visibile sopra la mesh
        g.materials = [m]
        return g
    }

    /// Croce 3D (mirino) di semilato R, lungo i 3 assi.
    static func croce3D(_ R: Float, colore: UIColor) -> SCNGeometry {
        let v: [SCNVector3] = [
            SCNVector3(-R, 0, 0), SCNVector3(R, 0, 0),
            SCNVector3(0, -R, 0), SCNVector3(0, R, 0),
            SCNVector3(0, 0, -R), SCNVector3(0, 0, R),
        ]
        let src = SCNGeometrySource(vertices: v)
        let elem = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 3, 4, 5), primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // sempre visibile sopra la mesh
        g.materials = [m]
        return g
    }

    /// Poligono pieno (triangolazione a ventaglio) — la faccia della facciata.
    static func facciaGeometria(_ pts: [SCNVector3], colore: UIColor) -> SCNGeometry? {
        guard pts.count >= 3 else { return nil }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        let src = SCNGeometrySource(vertices: pts)
        let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false        // evita z-fighting col muro sottostante
        g.materials = [m]
        return g
    }

    /// Facciata demo: muro suddiviso + balcone sporgente + triangoli sparsi
    /// (rumore da ripulire). Mesh INDICIZZATA singola, così la Fase 3 può
    /// cancellarne i triangoli direttamente dai buffer.
    static func demoMesh() -> EditableMesh {
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []

        // Muro: griglia 12×8 nel piano XY (z=0), 6×4 m.
        let cols = 12, rows = 8
        let W: Float = 6, H: Float = 4
        let base = UInt32(verts.count)
        for r in 0...rows {
            for c in 0...cols {
                let x = -W / 2 + W * Float(c) / Float(cols)
                let y = -H / 2 + H * Float(r) / Float(rows)
                verts.append(SIMD3(x, y, 0))
            }
        }
        let stride = UInt32(cols + 1)
        for r in 0..<UInt32(rows) {
            for c in 0..<UInt32(cols) {
                let i0 = base + r * stride + c
                let i1 = i0 + 1
                let i2 = i0 + stride
                let i3 = i2 + 1
                idx += [i0, i2, i1, i1, i2, i3]
            }
        }

        // Balcone: scatola sporgente in basso-centro, z∈[0,0.8].
        appendiScatola(&verts, &idx,
                       min: SIMD3(-1.0, -1.9, 0.0), max: SIMD3(1.0, -0.6, 0.8))

        // Rumore: triangoli sparsi staccati dal muro, da ripulire in Fase 3.
        let sparsi: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(3.6, 1.8, 1.4), SIMD3(3.9, 2.1, 1.2), SIMD3(3.4, 2.3, 1.6)),
            (SIMD3(-3.8, -1.2, 2.0), SIMD3(-3.4, -1.0, 2.2), SIMD3(-3.6, -0.7, 1.8)),
            (SIMD3(0.5, 2.6, 2.4), SIMD3(0.9, 2.8, 2.1), SIMD3(0.3, 3.0, 2.6)),
        ]
        for tri in sparsi {
            let b = UInt32(verts.count)
            verts += [tri.0, tri.1, tri.2]
            idx += [b, b + 1, b + 2]
        }

        var tris: [SIMD3<UInt32>] = []
        tris.reserveCapacity(idx.count / 3)
        var k = 0
        while k + 2 < idx.count { tris.append(SIMD3(idx[k], idx[k + 1], idx[k + 2])); k += 3 }
        return EditableMesh(vertices: verts, triangles: tris)
    }

    /// Aggiunge una scatola assi-allineata (12 triangoli) ai buffer.
    private static func appendiScatola(_ verts: inout [SIMD3<Float>],
                                       _ idx: inout [UInt32],
                                       min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        let b = UInt32(verts.count)
        verts += [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        let f: [UInt32] = [
            0, 1, 2, 0, 2, 3,   // retro (z=lo)
            4, 6, 5, 4, 7, 6,   // fronte (z=hi)
            0, 4, 5, 0, 5, 1,   // basso
            3, 2, 6, 3, 6, 7,   // alto
            0, 3, 7, 0, 7, 4,   // sinistra
            1, 5, 6, 1, 6, 2,   // destra
        ]
        idx += f.map { b + $0 }
    }

    /// Costruisce una `SCNGeometry` indicizzata con normali per-vertice calcolate.
    static func geometria(da verts: [SIMD3<Float>], indici: [UInt32],
                          colore: UIColor) -> SCNGeometry {
        // Normali: media delle normali delle facce incidenti.
        var normals = [SIMD3<Float>](repeating: .zero, count: verts.count)
        var i = 0
        while i + 2 < indici.count {
            let a = Int(indici[i]), b = Int(indici[i + 1]), c = Int(indici[i + 2])
            let n = cross(verts[b] - verts[a], verts[c] - verts[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            i += 3
        }
        normals = normals.map { simd_length($0) > 1e-6 ? simd_normalize($0) : SIMD3(0, 0, 1) }

        let vData = verts.withUnsafeBytes { Data($0) }
        let nData = normals.withUnsafeBytes { Data($0) }
        let st = MemoryLayout<SIMD3<Float>>.stride   // 16 (padded): SceneKit salta il pad

        let vSrc = SCNGeometrySource(
            data: vData, semantic: .vertex, vectorCount: verts.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: st)
        let nSrc = SCNGeometrySource(
            data: nData, semantic: .normal, vectorCount: normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: st)

        let iData = indici.withUnsafeBytes { Data($0) }
        let elem = SCNGeometryElement(
            data: iData, primitiveType: .triangles,
            primitiveCount: indici.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)

        let geo = SCNGeometry(sources: [vSrc, nSrc], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = colore
        mat.isDoubleSided = true            // mesh OC spesso senza winding coerente
        mat.lightingModel = .blinn          // risponde bene a directional+ambient (PBR serve IBL)
        // Clip live del box di lavoro: scarta i frammenti fuori dal box (GPU),
        // così stringendo il box si vede la mesh sparire in tempo reale.
        mat.shaderModifiers = [.surface: clipModifier]
        mat.setValue(SCNVector3Zero, forKey: "clipLo")
        mat.setValue(SCNVector3Zero, forKey: "clipHi")
        mat.setValue(NSValue(scnMatrix4: SCNMatrix4Identity), forKey: "clipInv")
        mat.setValue(Float(0), forKey: "clipOn")
        geo.materials = [mat]
        return geo
    }

    static let clipModifier = """
    #pragma arguments
    float3 clipLo;
    float3 clipHi;
    float4x4 clipInv;
    float clipOn;
    #pragma body
    if (clipOn > 0.5) {
        float4 wpos = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        float3 lp = (clipInv * wpos).xyz;
        if (lp.x < clipLo.x || lp.x > clipHi.x ||
            lp.y < clipLo.y || lp.y > clipHi.y ||
            lp.z < clipLo.z || lp.z > clipHi.z) {
            discard_fragment();
        }
    }
    """
}

// MARK: – Caricamento da sessione backend

/// Scarica la mesh della sessione dal backend e apre l'editor 3D.
/// 404 → nessuna mesh caricata dal Mac: mostra messaggio e tasto Chiudi.
struct EditorMesh3DCaricamentoView: View {
    let sessionId: String
    let onChiudi: () -> Void

    @State private var meshFile: URL?
    @State private var errore: String?
    @State private var pronto = false

    var body: some View {
        Group {
            if pronto {
                EditorMesh3DView(meshFile: meshFile,
                                 nome: "Mesh facciata",
                                 onChiudi: onChiudi)
            } else {
                ZStack {
                    EditorTheme.bg.ignoresSafeArea()
                    VStack(spacing: 12) {
                        if let errore {
                            Text("Mesh non disponibile")
                                .font(Theme.Typo.body(14))
                                .foregroundStyle(Theme.danger)
                            Text(errore)
                                .font(Theme.Typo.caption(11))
                                .foregroundStyle(EditorTheme.testoMuto)
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView().tint(EditorTheme.accento)
                            Text("Scarico la mesh…")
                                .font(Theme.Typo.caption())
                                .foregroundStyle(EditorTheme.testoMuto)
                        }
                        Button("Chiudi") { onChiudi() }
                            .foregroundStyle(EditorTheme.accento)
                    }
                    .padding(24)
                }
            }
        }
        .task(id: sessionId) { await carica() }
    }

    private func carica() async {
        do {
            let info = try await BackendAPIClient.shared.fetchMeshInfo(sessionId: sessionId)
            guard let main = info.main_obj ?? info.files.first else {
                errore = "La sessione non ha una mesh OBJ."
                pronto = true
                return
            }
            meshFile = try await BackendAPIClient.shared.downloadMeshFile(main)
            pronto = true
        } catch {
            errore = error.localizedDescription
            pronto = true
        }
    }
}

// MARK: – Preview (mesh demo, nessun asset)

#Preview {
    EditorMesh3DView()
}

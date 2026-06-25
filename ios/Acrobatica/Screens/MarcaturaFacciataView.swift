import SwiftUI

/// Editor di marcatura zone sull'ortofoto della facciata.
/// Il rilevatore segna poligoni/rettangoli ("Esclusa", "Da rifare",
/// "Misurabile", "Nota") con area in m² e perimetro in m calcolati
/// dalla scala ppm (px/m). Estetica scura stile Blender, touch-first.
///
/// Persistenza: JSON Codable (schema compatibile con la pipeline Python)
/// salvato automaticamente in Documents + condivisibile via share sheet.
struct MarcaturaFacciataView: View {
    @StateObject private var model: MarcaturaEditorModel
    private let onChiudi: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var mostraListaZone = false
    @State private var urlEsportazione: URL?

    init(immagine: UIImage,
         ppm: Double = 110,
         nomeDocumento: String = "marcatura_facciata",
         sessionId: String? = nil,
         onChiudi: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: MarcaturaEditorModel(
            immagine: immagine, ppm: ppm, nomeDocumento: nomeDocumento,
            sessionId: sessionId))
        self.onChiudi = onChiudi
    }

    var body: some View {
        VStack(spacing: 0) {
            barraSuperiore
            areaCanvas
            if model.zonaSelezionata != nil { pannelloProprieta }
            barraStrumenti
        }
        .background(EditorTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await model.caricaProposte() }
        .alert("Marcatura inviata", isPresented: Binding(
            get: { model.messaggioUploadOk != nil },
            set: { if !$0 { model.messaggioUploadOk = nil } }
        )) {
            Button("OK") { model.messaggioUploadOk = nil }
        } message: {
            Text(model.messaggioUploadOk ?? "")
        }
        .alert("Invio fallito", isPresented: Binding(
            get: { model.messaggioUploadErrore != nil },
            set: { if !$0 { model.messaggioUploadErrore = nil } }
        )) {
            Button("Riprova") { Task { await model.inviaAlBackend() } }
            Button("Annulla", role: .cancel) { model.messaggioUploadErrore = nil }
        } message: {
            Text(model.messaggioUploadErrore ?? "")
        }
        .sheet(isPresented: $mostraListaZone) { listaZoneSheet }
        .sheet(isPresented: Binding(
            get: { urlEsportazione != nil },
            set: { if !$0 { urlEsportazione = nil } }
        )) {
            if let url = urlEsportazione {
                CondivisioneView(elementi: [url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: – Barra superiore

    private var barraSuperiore: some View {
        HStack(spacing: 14) {
            Button {
                model.salva()
                if let onChiudi { onChiudi() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EditorTheme.testo)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Marcatura zone")
                    .font(Theme.Typo.title(15))
                    .foregroundStyle(EditorTheme.testo)
                Text(String(format: "%.0f×%.0f px · %.0f px/m",
                            model.dimensioneImmagine.width,
                            model.dimensioneImmagine.height,
                            model.ppm))
                    .font(Theme.Typo.caption(10))
                    .foregroundStyle(EditorTheme.testoMuto)
            }

            Spacer()

            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 36, height: 36)
            }
            .disabled(!model.puoUndo)
            .foregroundStyle(model.puoUndo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))

            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 36, height: 36)
            }
            .disabled(!model.puoRedo)
            .foregroundStyle(model.puoRedo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))

            if model.sessionId != nil {
                Button {
                    Task { await model.inviaAlBackend() }
                } label: {
                    Group {
                        switch model.statoUpload {
                        case .inCorso:
                            ProgressView().tint(EditorTheme.accento).scaleEffect(0.8)
                        case .riuscito:
                            Image(systemName: "checkmark.icloud")
                                .foregroundStyle(Color(hexString: "#1FA463"))
                        case .fallito:
                            Image(systemName: "exclamationmark.icloud")
                                .foregroundStyle(Theme.danger)
                        case .nessuno:
                            Image(systemName: "icloud.and.arrow.up")
                                .foregroundStyle(EditorTheme.testo)
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .disabled(model.statoUpload == .inCorso)
            }

            Button {
                model.salva()
                urlEsportazione = model.urlEsportazione()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(EditorTheme.testo)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EditorTheme.panel)
        .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .bottom)
    }

    // MARK: – Canvas

    private var areaCanvas: some View {
        GeometryReader { geo in
            ZStack {
                EditorTheme.bg
                Canvas { ctx, _ in
                    disegna(in: &ctx)
                }
                EditorGestureView(
                    onTap: { model.gestisciTap($0) },
                    onDoubleTap: { _ in
                        withAnimation(.easeOut(duration: 0.2)) { model.adattaAllaVista(geo.size) }
                    },
                    onDrag: { fase, p in model.gestisciDrag(fase, p) },
                    onPinch: { fase, delta, centro in model.gestisciPinch(fase, delta: delta, centro: centro) },
                    onPanDueDita: { fase, delta in model.gestisciPanDueDita(fase, delta: delta) }
                )
                hudOverlay
            }
            .clipped()
            .onAppear { model.adattaAllaVista(geo.size) }
            .onChange(of: geo.size) { model.adattaAllaVista($0) }
        }
    }

    /// HUD: coordinate del tocco in metri (origine in basso a sx) + aree per tipo.
    private var hudOverlay: some View {
        VStack {
            if let info = model.infoProposte {
                Text(info)
                    .font(Theme.Typo.caption(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(EditorTheme.accento.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    if let t = model.ultimoToccoPx {
                        Text(String(format: "x %.2f m   y %.2f m",
                                    t.x / model.ppm,
                                    (model.dimensioneImmagine.height - t.y) / model.ppm))
                            .font(Theme.Typo.mono(11))
                            .foregroundStyle(EditorTheme.accento)
                    }
                    ForEach(TipoZona.allCases) { tipo in
                        let valore = tipo.isLineare
                            ? model.lunghezzaTotale(tipo) : model.areaTotale(tipo)
                        if valore > 0 {
                            HStack(spacing: 5) {
                                Circle().fill(tipo.colore).frame(width: 7, height: 7)
                                Text(String(format: tipo.isLineare ? "%@  %.2f m" : "%@  %.2f m²",
                                            tipo.etichetta, valore))
                                    .font(Theme.Typo.mono(10))
                                    .foregroundStyle(EditorTheme.testo)
                            }
                        }
                    }
                }
                .padding(8)
                .background(EditorTheme.panel.opacity(0.88),
                            in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            Spacer()
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    // MARK: – Disegno (Canvas)

    private func disegna(in ctx: inout GraphicsContext) {
        // Ortofoto
        let img = model.immagine
        let rect = CGRect(x: model.offset.x, y: model.offset.y,
                          width: img.size.width * model.scala,
                          height: img.size.height * model.scala)
        ctx.draw(Image(uiImage: img), in: rect)
        ctx.stroke(Path(rect), with: .color(.white.opacity(0.15)), lineWidth: 1)

        // Zone
        for zona in model.zone where zona.visibile {
            disegnaZona(zona, in: &ctx, selezionata: zona.id == model.selezioneId)
        }

        // Bozze
        disegnaBozzaPoligono(in: &ctx)
        disegnaBozzaRettangolo(in: &ctx)

        // Maniglie della zona selezionata (modifica vertici)
        if model.strumento == .seleziona,
           let zona = model.zonaSelezionata, zona.visibile {
            for p in zona.puntiPx {
                disegnaManiglia(model.puntoSchermo(p), in: &ctx)
            }
        }
    }

    private func disegnaZona(_ zona: ZonaFacciata,
                             in ctx: inout GraphicsContext,
                             selezionata: Bool) {
        if zona.tipo.isLineare {
            disegnaLinea(zona, in: &ctx, selezionata: selezionata)
            return
        }
        guard zona.puntiPx.count >= 3 else { return }
        var path = Path()
        let punti = zona.puntiPx.map { model.puntoSchermo($0) }
        path.move(to: punti[0])
        for p in punti.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()

        ctx.fill(path, with: .color(zona.tipo.colore.opacity(selezionata ? 0.38 : 0.25)))

        // Tratteggio diagonale per le zone escluse
        if zona.tipo.tratteggioDiagonale {
            let b = path.boundingRect
            var righe = Path()
            let passo: CGFloat = 14
            var x = b.minX - b.height
            while x < b.maxX {
                righe.move(to: CGPoint(x: x, y: b.maxY))
                righe.addLine(to: CGPoint(x: x + b.height, y: b.minY))
                x += passo
            }
            ctx.drawLayer { strato in
                strato.clip(to: path)
                strato.stroke(righe, with: .color(zona.tipo.colore.opacity(0.55)), lineWidth: 1.5)
            }
        }

        ctx.stroke(path,
                   with: .color(selezionata ? EditorTheme.accento : zona.tipo.colore),
                   style: StrokeStyle(lineWidth: selezionata ? 2.5 : 1.5,
                                      lineJoin: .round))

        // Etichetta: nome + area
        let centro = model.puntoSchermo(zona.baricentro)
        ctx.draw(
            Text(zona.nome)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white),
            at: CGPoint(x: centro.x, y: centro.y - 7))
        ctx.draw(
            Text(String(format: "%.2f m²", zona.areaM2))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.85)),
            at: CGPoint(x: centro.x, y: centro.y + 7))
    }

    /// Polilinea aperta (tipo lineare): solo tratto + etichetta lunghezza in m.
    private func disegnaLinea(_ zona: ZonaFacciata,
                              in ctx: inout GraphicsContext,
                              selezionata: Bool) {
        guard zona.puntiPx.count >= 2 else { return }
        let punti = zona.puntiPx.map { model.puntoSchermo($0) }
        var path = Path()
        path.move(to: punti[0])
        for p in punti.dropFirst() { path.addLine(to: p) }

        // Alone scuro sotto per leggibilità sulla foto, poi il tratto colorato.
        ctx.stroke(path, with: .color(.black.opacity(0.45)),
                   style: StrokeStyle(lineWidth: selezionata ? 6 : 5,
                                      lineCap: .round, lineJoin: .round))
        ctx.stroke(path,
                   with: .color(selezionata ? EditorTheme.accento : zona.tipo.colore),
                   style: StrokeStyle(lineWidth: selezionata ? 3.5 : 2.5,
                                      lineCap: .round, lineJoin: .round))

        // Etichetta a metà percorso: nome + lunghezza
        let medio = punti[punti.count / 2]
        ctx.draw(
            Text(zona.nome)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white),
            at: CGPoint(x: medio.x, y: medio.y - 16))
        ctx.draw(
            Text(String(format: "%.2f m", zona.perimetroM))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.85)),
            at: CGPoint(x: medio.x, y: medio.y - 4))
    }

    private func disegnaBozzaPoligono(in ctx: inout GraphicsContext) {
        let punti = model.bozzaPoligono.map { model.puntoSchermo($0) }
        guard !punti.isEmpty else { return }

        if punti.count >= 2 {
            var path = Path()
            path.move(to: punti[0])
            for p in punti.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(EditorTheme.accento),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        for (i, p) in punti.enumerated() {
            if i == 0 && punti.count >= 3 && !model.tipoCorrente.isLineare {
                // Primo vertice evidenziato: tap qui per chiudere
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)),
                           with: .color(EditorTheme.accento), lineWidth: 2)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                     with: .color(EditorTheme.accento))
        }
    }

    private func disegnaBozzaRettangolo(in ctx: inout GraphicsContext) {
        guard let b = model.bozzaRettangolo else { return }
        let a = model.puntoSchermo(b.a)
        let c = model.puntoSchermo(b.b)
        // Col tipo lineare la bozza è un segmento dritto, non un rettangolo.
        if model.tipoCorrente.isLineare {
            var linea = Path()
            linea.move(to: a)
            linea.addLine(to: c)
            ctx.stroke(linea, with: .color(EditorTheme.accento),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
            return
        }
        let rect = CGRect(x: min(a.x, c.x), y: min(a.y, c.y),
                          width: abs(c.x - a.x), height: abs(c.y - a.y))
        ctx.fill(Path(rect), with: .color(model.tipoCorrente.colore.opacity(0.2)))
        ctx.stroke(Path(rect), with: .color(EditorTheme.accento),
                   style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    private func disegnaManiglia(_ p: CGPoint, in ctx: inout GraphicsContext) {
        // Visivamente 16pt; l'hit area in MarcaturaEditorModel è ≥44pt
        let r = CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
        ctx.fill(Path(r), with: .color(.white))
        ctx.stroke(Path(r), with: .color(EditorTheme.accento), lineWidth: 2)
    }

    // MARK: – Pannello proprietà (zona selezionata)

    private var pannelloProprieta: some View {
        VStack(spacing: 8) {
            if let zona = model.zonaSelezionata {
                HStack(spacing: 10) {
                    Circle().fill(zona.tipo.colore).frame(width: 10, height: 10)

                    TextField("Nome zona", text: Binding(
                        get: { model.zonaSelezionata?.nome ?? "" },
                        set: { model.impostaNome($0) }
                    ))
                    .font(Theme.Typo.body(14, .semibold))
                    .foregroundStyle(EditorTheme.testo)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit { model.salva() }

                    Spacer()

                    Menu {
                        ForEach(TipoZona.allCases) { tipo in
                            Button {
                                model.cambiaTipo(tipo)
                            } label: {
                                Label(tipo.etichetta, systemImage: tipo.icona)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(zona.tipo.etichetta)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                        }
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundStyle(zona.tipo.colore)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(zona.tipo.colore.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 7))
                    }

                    Button { model.toggleVisibilita(zona.id) } label: {
                        Image(systemName: zona.visibile ? "eye" : "eye.slash")
                            .foregroundStyle(EditorTheme.testo)
                            .frame(width: 32, height: 32)
                    }

                    Button { model.eliminaZona(zona.id) } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.danger)
                            .frame(width: 32, height: 32)
                    }
                }

                HStack(spacing: 16) {
                    if zona.tipo.isLineare {
                        Label(String(format: "Lunghezza %.2f m", zona.perimetroM),
                              systemImage: "ruler")
                    } else {
                        Label(String(format: "Area %.2f m²", zona.areaM2),
                              systemImage: "square.dashed")
                        Label(String(format: "Perimetro %.2f m", zona.perimetroM),
                              systemImage: "ruler")
                    }
                    Text("\(zona.puntiPx.count) vertici")
                    Spacer()
                }
                .font(Theme.Typo.mono(11))
                .foregroundStyle(EditorTheme.testoMuto)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(EditorTheme.panel)
        .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
    }

    // MARK: – Barra strumenti (zona pollice)

    private var barraStrumenti: some View {
        VStack(spacing: 8) {
            // Barra contestuale per la bozza poligono
            if model.strumento == .poligono && !model.bozzaPoligono.isEmpty {
                HStack(spacing: 10) {
                    Text("\(model.bozzaPoligono.count) punti")
                        .font(Theme.Typo.caption(11))
                        .foregroundStyle(EditorTheme.testoMuto)
                    Spacer()
                    Button {
                        model.rimuoviUltimoVerticeBozza()
                    } label: {
                        Label("Indietro", systemImage: "arrow.left.to.line")
                            .font(Theme.Typo.caption(12, .semibold))
                    }
                    .foregroundStyle(EditorTheme.testo)
                    Button {
                        model.annullaBozza()
                    } label: {
                        Label("Annulla", systemImage: "xmark")
                            .font(Theme.Typo.caption(12, .semibold))
                    }
                    .foregroundStyle(Theme.danger)
                    Button {
                        model.chiudiPoligono()
                    } label: {
                        Label(model.tipoCorrente.isLineare ? "Termina linea" : "Chiudi poligono",
                              systemImage: "checkmark.circle.fill")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.accento,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .disabled(model.bozzaPoligono.count < model.minimoPuntiBozza)
                    .opacity(model.bozzaPoligono.count < model.minimoPuntiBozza ? 0.5 : 1)
                }
                .padding(.horizontal, 12)
            }

            HStack(spacing: 6) {
                ForEach(StrumentoMarcatura.allCases) { strumento in
                    PulsanteStrumento(
                        strumento: strumento,
                        attivo: model.strumento == strumento
                    ) {
                        model.strumento = strumento
                    }
                }

                Rectangle().fill(EditorTheme.hair)
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 2)

                // Tipo di zona corrente (per i nuovi disegni)
                Menu {
                    ForEach(TipoZona.allCases) { tipo in
                        Button {
                            model.tipoCorrente = tipo
                        } label: {
                            Label(tipo.etichetta, systemImage: tipo.icona)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(model.tipoCorrente.colore).frame(width: 9, height: 9)
                        Text(model.tipoCorrente.etichetta)
                            .font(Theme.Typo.caption(11, .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(EditorTheme.testo)
                    .padding(.horizontal, 9)
                    .frame(height: 44)
                    .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 9))
                }

                Spacer(minLength: 4)

                // Lista zone (outliner)
                Button { mostraListaZone = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(EditorTheme.testo)
                            .frame(width: 44, height: 44)
                            .background(EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 9))
                        if !model.zone.isEmpty {
                            Text("\(model.zone.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(EditorTheme.accento, in: Capsule())
                                .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(EditorTheme.panel)
        .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
    }

    // MARK: – Lista zone (outliner stile Blender, sheet dal basso)

    private var listaZoneSheet: some View {
        NavigationStack {
            Group {
                if model.zone.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 32))
                            .foregroundStyle(EditorTheme.testoMuto)
                        Text("Nessuna zona marcata")
                            .font(Theme.Typo.body(14))
                            .foregroundStyle(EditorTheme.testoMuto)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(EditorTheme.bg)
                } else {
                    List {
                        ForEach(model.zone) { zona in
                            rigaZona(zona)
                                .listRowBackground(
                                    zona.id == model.selezioneId
                                        ? EditorTheme.accento.opacity(0.18)
                                        : EditorTheme.panel)
                        }
                        .onDelete { offsets in
                            model.eliminaZone(offsets)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(EditorTheme.bg)
                }
            }
            .navigationTitle("Zone (\(model.zone.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { mostraListaZone = false }
                        .foregroundStyle(EditorTheme.accento)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func rigaZona(_ zona: ZonaFacciata) -> some View {
        HStack(spacing: 10) {
            Button {
                model.toggleVisibilita(zona.id)
            } label: {
                Image(systemName: zona.visibile ? "eye" : "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(zona.visibile ? EditorTheme.testo : EditorTheme.testoMuto)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 3)
                .fill(zona.tipo.colore)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(zona.nome)
                    .font(Theme.Typo.body(14, .semibold))
                    .foregroundStyle(EditorTheme.testo)
                Text("\(zona.tipo.etichetta) · \(String(format: zona.tipo.isLineare ? "%.2f m" : "%.2f m²", zona.tipo.isLineare ? zona.perimetroM : zona.areaM2))")
                    .font(Theme.Typo.caption(11))
                    .foregroundStyle(EditorTheme.testoMuto)
            }

            Spacer()

            if zona.id == model.selezioneId {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(EditorTheme.accento)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selezioneId = zona.id
            mostraListaZone = false
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.eliminaZona(zona.id)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
    }
}

// MARK: – Tema editor (scuro stile Blender)

/// Palette dedicata all'editor: grigi scuri Blender + accento arancio.
/// (Il resto dell'app è chiaro — l'editor è volutamente "da workstation".)
enum EditorTheme {
    static let bg        = Color(hex: 0x232323)
    static let panel     = Color(hex: 0x2D2D2D)
    static let panelAlt  = Color(hex: 0x3A3A3A)
    static let hair      = Color.white.opacity(0.08)
    static let testo     = Color(hex: 0xE6E6E6)
    static let testoMuto = Color.white.opacity(0.55)
    static let accento   = Color(hex: 0xE87D0D)   // arancio Blender
}

// MARK: – Strumenti

enum StrumentoMarcatura: String, CaseIterable, Identifiable {
    case seleziona, mano, poligono, rettangolo

    var id: String { rawValue }

    var icona: String {
        switch self {
        case .seleziona:  return "cursorarrow"
        case .mano:       return "hand.raised"
        case .poligono:   return "hexagon"
        case .rettangolo: return "rectangle.dashed"
        }
    }

    var etichetta: String {
        switch self {
        case .seleziona:  return "Seleziona"
        case .mano:       return "Mano"
        case .poligono:   return "Poligono"
        case .rettangolo: return "Rettangolo"
        }
    }
}

/// Pulsante strumento 44×44 (zona pollice, hit area touch-friendly).
private struct PulsanteStrumento: View {
    let strumento: StrumentoMarcatura
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
            .frame(width: 52, height: 44)
            .background(attivo ? EditorTheme.accento : EditorTheme.panelAlt,
                        in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

// MARK: – Modello editor

/// Bozza rettangolo in corso di disegno (coordinate px immagine).
struct BozzaRettangolo: Equatable {
    var a: CGPoint
    var b: CGPoint
}

/// Stato + logica dell'editor: zone, vista (zoom/pan), strumenti,
/// undo/redo (max 50 passi) e persistenza JSON.
/// Stato dell'invio della marcatura al backend.
enum StatoUploadMarcatura: Equatable {
    case nessuno, inCorso, riuscito, fallito
}

@MainActor
final class MarcaturaEditorModel: ObservableObject {
    let immagine: UIImage
    let ppm: Double
    let nomeDocumento: String
    /// Sessione backend a cui inviare la marcatura (nil = solo locale/share).
    let sessionId: String?

    @Published var statoUpload: StatoUploadMarcatura = .nessuno
    @Published var messaggioUploadOk: String?
    @Published var messaggioUploadErrore: String?
    /// Banner informativo sulle zone proposte automaticamente (auto-dismiss).
    @Published var infoProposte: String?
    private var proposteRichieste = false

    @Published var zone: [ZonaFacciata] = []
    @Published var selezioneId: UUID?
    @Published var strumento: StrumentoMarcatura = .poligono
    @Published var tipoCorrente: TipoZona = .esclusa
    @Published var bozzaPoligono: [CGPoint] = []
    @Published var bozzaRettangolo: BozzaRettangolo?
    @Published var ultimoToccoPx: CGPoint?

    // Vista (trasformazione immagine → schermo: pSchermo = offset + pImg * scala)
    @Published var scala: CGFloat = 1
    @Published var offset: CGPoint = .zero
    private var scalaFit: CGFloat = 1

    // Undo/redo a snapshot
    @Published private(set) var undoStack: [[ZonaFacciata]] = []
    @Published private(set) var redoStack: [[ZonaFacciata]] = []
    private let maxUndo = 50

    /// Raggio (pt schermo) entro cui un tocco "prende" una maniglia: ≥44pt di hit area.
    private let raggioManiglia: CGFloat = 26

    init(immagine: UIImage, ppm: Double, nomeDocumento: String,
         sessionId: String? = nil) {
        self.immagine = immagine
        self.ppm = ppm
        self.nomeDocumento = nomeDocumento
        self.sessionId = sessionId
        carica()
    }

    var dimensioneImmagine: CGSize { immagine.size }
    var puoUndo: Bool { !undoStack.isEmpty }
    var puoRedo: Bool { !redoStack.isEmpty }

    var zonaSelezionata: ZonaFacciata? {
        zone.first { $0.id == selezioneId }
    }

    // MARK: Trasformazioni di coordinate

    func puntoSchermo(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * scala, y: offset.y + p.y * scala)
    }

    func puntoImmagine(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scala, y: (p.y - offset.y) / scala)
    }

    private func clampImg(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(dimensioneImmagine.width, p.x)),
                y: max(0, min(dimensioneImmagine.height, p.y)))
    }

    /// Fit dell'immagine nella vista (double-tap / primo layout).
    func adattaAllaVista(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let s = min(size.width / dimensioneImmagine.width,
                    size.height / dimensioneImmagine.height) * 0.96
        scalaFit = s
        scala = s
        offset = CGPoint(x: (size.width - dimensioneImmagine.width * s) / 2,
                         y: (size.height - dimensioneImmagine.height * s) / 2)
    }

    // MARK: Gesti

    func gestisciTap(_ pSchermo: CGPoint) {
        let pImg = clampImg(puntoImmagine(pSchermo))
        ultimoToccoPx = pImg
        switch strumento {
        case .poligono:
            // Tap sul primo vertice → chiudi (le linee si terminano col bottone)
            if !tipoCorrente.isLineare,
               bozzaPoligono.count >= 3,
               let primo = bozzaPoligono.first,
               distanza(puntoSchermo(primo), pSchermo) <= raggioManiglia {
                chiudiPoligono()
                return
            }
            bozzaPoligono.append(pImg)
        case .seleziona:
            // Topmost (ultima disegnata) che contiene il punto; per le linee
            // la tolleranza di hit scala con lo zoom (≈ raggioManiglia su schermo).
            let tolleranzaPx = raggioManiglia / max(scala, 0.0001)
            selezioneId = zone.last(where: {
                $0.visibile && $0.contiene(pImg, tolleranzaLineaPx: tolleranzaPx)
            })?.id
        case .rettangolo, .mano:
            break
        }
    }

    private enum DestinazioneDrag {
        case vista
        case rettangolo
        case verticeBozza(Int)
        case verticeZona(zona: Int, vertice: Int)
    }
    private var destinazioneDrag: DestinazioneDrag?
    private var ultimaPosDrag: CGPoint = .zero

    func gestisciDrag(_ fase: FaseGesto, _ pSchermo: CGPoint) {
        let pImg = clampImg(puntoImmagine(pSchermo))

        switch fase {
        case .inizio:
            ultimaPosDrag = pSchermo
            ultimoToccoPx = pImg
            destinazioneDrag = .vista   // default: pan a un dito (forgiving)
            switch strumento {
            case .rettangolo:
                destinazioneDrag = .rettangolo
                bozzaRettangolo = BozzaRettangolo(a: pImg, b: pImg)
            case .poligono:
                if let i = indiceVerticeVicino(bozzaPoligono, a: pSchermo) {
                    destinazioneDrag = .verticeBozza(i)
                }
            case .seleziona:
                if let zi = zone.firstIndex(where: { $0.id == selezioneId }),
                   let vi = indiceVerticeVicino(zone[zi].puntiPx, a: pSchermo) {
                    registraUndo()
                    destinazioneDrag = .verticeZona(zona: zi, vertice: vi)
                }
            case .mano:
                break
            }

        case .cambiamento, .fine:
            switch destinazioneDrag {
            case .vista, .none:
                offset.x += pSchermo.x - ultimaPosDrag.x
                offset.y += pSchermo.y - ultimaPosDrag.y
            case .rettangolo:
                bozzaRettangolo?.b = pImg
            case .verticeBozza(let i):
                if bozzaPoligono.indices.contains(i) { bozzaPoligono[i] = pImg }
            case .verticeZona(let zi, let vi):
                if zone.indices.contains(zi), zone[zi].puntiPx.indices.contains(vi) {
                    zone[zi].puntiPx[vi] = pImg
                    zone[zi].aggiornaMetriche(ppm: ppm)
                }
            }
            ultimaPosDrag = pSchermo
            ultimoToccoPx = pImg

            if fase == .fine {
                if case .rettangolo = destinazioneDrag { commitRettangolo() }
                if case .verticeZona = destinazioneDrag { salva() }
                destinazioneDrag = nil
            }
        }
    }

    func gestisciPinch(_ fase: FaseGesto, delta: CGFloat, centro: CGPoint) {
        guard fase == .cambiamento else { return }
        let minimo = scalaFit * 0.3
        let massimo: CGFloat = max(20, scalaFit * 40)
        let nuova = max(minimo, min(massimo, scala * delta))
        let f = nuova / scala
        // Zoom verso il punto di pinch
        offset = CGPoint(x: centro.x - (centro.x - offset.x) * f,
                         y: centro.y - (centro.y - offset.y) * f)
        scala = nuova
    }

    func gestisciPanDueDita(_ fase: FaseGesto, delta: CGSize) {
        guard fase == .cambiamento else { return }
        offset.x += delta.width
        offset.y += delta.height
    }

    private func indiceVerticeVicino(_ punti: [CGPoint], a pSchermo: CGPoint) -> Int? {
        let candidati = punti.enumerated()
            .map { (i: $0.offset, d: distanza(puntoSchermo($0.element), pSchermo)) }
            .filter { $0.d <= raggioManiglia }
        return candidati.min(by: { $0.d < $1.d })?.i
    }

    private func distanza(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Creazione zone

    /// Punti minimi per chiudere la bozza corrente (2 per le linee, 3 per i poligoni).
    var minimoPuntiBozza: Int { tipoCorrente.isLineare ? 2 : 3 }

    func chiudiPoligono() {
        guard bozzaPoligono.count >= minimoPuntiBozza else { return }
        registraUndo()
        let zona = ZonaFacciata(nome: nomeNuovaZona(),
                                tipo: tipoCorrente,
                                puntiPx: bozzaPoligono,
                                ppm: ppm)
        zone.append(zona)
        bozzaPoligono = []
        selezioneId = zona.id
        salva()
    }

    func rimuoviUltimoVerticeBozza() {
        guard !bozzaPoligono.isEmpty else { return }
        bozzaPoligono.removeLast()
    }

    func annullaBozza() {
        bozzaPoligono = []
        bozzaRettangolo = nil
    }

    private func commitRettangolo() {
        defer { bozzaRettangolo = nil }
        // Col tipo lineare il drag crea un segmento dritto A→B (no rettangolo).
        if tipoCorrente.isLineare {
            guard let b = bozzaRettangolo,
                  hypot(b.b.x - b.a.x, b.b.y - b.a.y) > 4 else { return }
            registraUndo()
            let zona = ZonaFacciata(nome: nomeNuovaZona(),
                                    tipo: tipoCorrente,
                                    puntiPx: [b.a, b.b],
                                    ppm: ppm)
            zone.append(zona)
            selezioneId = zona.id
            salva()
            return
        }
        guard let b = bozzaRettangolo,
              abs(b.b.x - b.a.x) > 4, abs(b.b.y - b.a.y) > 4 else { return }
        registraUndo()
        let x0 = min(b.a.x, b.b.x), x1 = max(b.a.x, b.b.x)
        let y0 = min(b.a.y, b.b.y), y1 = max(b.a.y, b.b.y)
        let zona = ZonaFacciata(nome: nomeNuovaZona(),
                                tipo: tipoCorrente,
                                puntiPx: [CGPoint(x: x0, y: y0),
                                          CGPoint(x: x1, y: y0),
                                          CGPoint(x: x1, y: y1),
                                          CGPoint(x: x0, y: y1)],
                                ppm: ppm)
        zone.append(zona)
        selezioneId = zona.id
        salva()
    }

    private func nomeNuovaZona() -> String {
        "Zona \(zone.count + 1)"
    }

    // MARK: Operazioni su zone

    func impostaNome(_ nome: String) {
        guard let i = zone.firstIndex(where: { $0.id == selezioneId }) else { return }
        zone[i].nome = nome
    }

    func cambiaTipo(_ tipo: TipoZona) {
        guard let i = zone.firstIndex(where: { $0.id == selezioneId }) else { return }
        registraUndo()
        zone[i].tipo = tipo
        zone[i].aggiornaMetriche(ppm: ppm)   // lineare ↔ poligono cambia la misura
        salva()
    }

    func toggleVisibilita(_ id: UUID) {
        guard let i = zone.firstIndex(where: { $0.id == id }) else { return }
        registraUndo()
        zone[i].visibile.toggle()
        salva()
    }

    func eliminaZona(_ id: UUID) {
        registraUndo()
        zone.removeAll { $0.id == id }
        if selezioneId == id { selezioneId = nil }
        salva()
    }

    func eliminaZone(_ offsets: IndexSet) {
        registraUndo()
        let rimosse = offsets.map { zone[$0].id }
        zone.remove(atOffsets: offsets)
        if let sel = selezioneId, rimosse.contains(sel) { selezioneId = nil }
        salva()
    }

    /// Somma delle aree (m²) per tipo, solo zone VISIBILI (quelle nascoste
    /// sono "spente" dall'operatore e non devono contare nel preventivo).
    func areaTotale(_ tipo: TipoZona) -> Double {
        zone.filter { $0.tipo == tipo && $0.visibile }.reduce(0) { $0 + $1.areaM2 }
    }

    /// Somma delle lunghezze (m) per i tipi lineari, solo zone visibili.
    func lunghezzaTotale(_ tipo: TipoZona) -> Double {
        zone.filter { $0.tipo == tipo && $0.visibile }.reduce(0) { $0 + $1.perimetroM }
    }

    // MARK: Pre-marcatura automatica (zone fuori-piano proposte dal backend)

    /// Scarica le zone "Esclusa" proposte (balconi/aggetti >15 cm dal piano)
    /// e le aggiunge come bozze da confermare. Solo al primo ingresso e solo
    /// se l'operatore non ha ancora marcato nulla; fallisce in silenzio se il
    /// backend non ha ancora i piani (GET /planes non eseguito).
    func caricaProposte() async {
        guard let sessionId, zone.isEmpty, !proposteRichieste else { return }
        proposteRichieste = true
        guard let data = try? await BackendAPIClient.shared.fetchZoneProposals(
                  sessionId: sessionId, ppm: ppm),
              let doc = try? MarcaturaFacciata.da(jsonData: data),
              !doc.zone.isEmpty else { return }

        // Le proposte sono nei px dell'ortofoto derivata dal piano: riscala
        // alle dimensioni dell'immagine mostrata, ma solo se le proporzioni
        // combaciano (altrimenti l'immagine non è quell'ortofoto: ignora).
        let dw = Double(doc.larghezzaPx), dh = Double(doc.altezzaPx)
        let iw = Double(dimensioneImmagine.width), ih = Double(dimensioneImmagine.height)
        guard dw > 0, dh > 0, ih > 0 else { return }
        guard abs(dw / dh - iw / ih) / (iw / ih) < 0.03 else {
            mostraInfoProposte("Zone automatiche ignorate: l'immagine non corrisponde all'ortofoto del piano")
            return
        }
        let sx = iw / dw, sy = ih / dh
        registraUndo()
        for var z in doc.zone {
            z.puntiPx = z.puntiPx.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            z.aggiornaMetriche(ppm: ppm)
            zone.append(z)
        }
        salva()
        mostraInfoProposte("\(doc.zone.count) zone fuori-piano proposte automaticamente — verifica e ritocca")
    }

    private func mostraInfoProposte(_ testo: String) {
        infoProposte = testo
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.infoProposte = nil
        }
    }

    // MARK: Invio al backend

    /// Invia il documento di marcatura al backend (PUT idempotente).
    /// Il backend ricalcola le metriche e le usa per i m² del preventivo.
    func inviaAlBackend() async {
        guard let sessionId else { return }
        salva()
        statoUpload = .inCorso
        messaggioUploadErrore = nil
        do {
            let json = try documento().jsonData()
            let esito = try await BackendAPIClient.shared.uploadZoneMarkup(
                sessionId: sessionId, jsonData: json)
            statoUpload = .riuscito
            var righe: [String] = ["\(esito.zone_count) zone salvate sul server."]
            for (tipo, area) in esito.area_m2_per_tipo.sorted(by: { $0.key < $1.key }) {
                righe.append(String(format: "%@: %.2f m²", tipo, area))
            }
            for (tipo, m) in esito.lunghezza_m_per_tipo.sorted(by: { $0.key < $1.key }) {
                righe.append(String(format: "%@: %.2f m", tipo, m))
            }
            messaggioUploadOk = righe.joined(separator: "\n")
        } catch {
            statoUpload = .fallito
            messaggioUploadErrore = error.localizedDescription
        }
    }

    // MARK: Undo / redo

    func registraUndo() {
        undoStack.append(zone)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(zone)
        zone = snapshot
        sanificaSelezione()
        salva()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(zone)
        zone = snapshot
        sanificaSelezione()
        salva()
    }

    private func sanificaSelezione() {
        if let sel = selezioneId, !zone.contains(where: { $0.id == sel }) {
            selezioneId = nil
        }
    }

    // MARK: Persistenza (Documents + export)

    func documento() -> MarcaturaFacciata {
        MarcaturaFacciata(ppm: ppm,
                          larghezzaPx: Int(dimensioneImmagine.width.rounded()),
                          altezzaPx: Int(dimensioneImmagine.height.rounded()),
                          zone: zone)
    }

    private var urlSalvataggio: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let cartella = docs.appendingPathComponent("marcature_facciata", isDirectory: true)
        try? FileManager.default.createDirectory(at: cartella,
                                                 withIntermediateDirectories: true)
        return cartella.appendingPathComponent("\(nomeDocumento).json")
    }

    /// Salvataggio automatico locale (chiamato a ogni commit).
    func salva() {
        guard let url = urlSalvataggio else { return }
        do {
            try documento().jsonData().write(to: url, options: .atomic)
        } catch {
            print("MarcaturaEditor: salvataggio fallito — \(error)")
        }
    }

    private func carica() {
        guard let url = urlSalvataggio,
              let data = try? Data(contentsOf: url),
              let doc = try? MarcaturaFacciata.da(jsonData: data) else { return }
        zone = doc.zone
    }

    /// File temporaneo per la condivisione del JSON.
    func urlEsportazione() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(nomeDocumento).json")
        do {
            try documento().jsonData().write(to: url, options: .atomic)
            return url
        } catch {
            print("MarcaturaEditor: export fallito — \(error)")
            return nil
        }
    }
}

// MARK: – Share sheet UIKit

/// Wrapper UIActivityViewController per condividere il JSON di marcatura.
private struct CondivisioneView: UIViewControllerRepresentable {
    let elementi: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: elementi, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: – Caricamento da URL (aggancio col flusso backend)

/// Scarica l'ortofoto dal backend e apre l'editor di marcatura.
/// Punto di aggancio usato da RisultatoPanoramaView.
struct MarcaturaFacciataCaricamentoView: View {
    let url: URL
    let ppm: Double
    let nomeDocumento: String
    var sessionId: String? = nil
    let onChiudi: () -> Void

    @State private var immagine: UIImage?
    @State private var errore: String?

    var body: some View {
        Group {
            if let immagine {
                MarcaturaFacciataView(immagine: immagine,
                                      ppm: ppm,
                                      nomeDocumento: nomeDocumento,
                                      sessionId: sessionId,
                                      onChiudi: onChiudi)
            } else {
                ZStack {
                    EditorTheme.bg.ignoresSafeArea()
                    VStack(spacing: 12) {
                        if let errore {
                            Text("Ortofoto non scaricabile")
                                .font(Theme.Typo.body(14))
                                .foregroundStyle(Theme.danger)
                            Text(errore)
                                .font(Theme.Typo.caption(11))
                                .foregroundStyle(EditorTheme.testoMuto)
                        } else {
                            ProgressView().tint(EditorTheme.accento)
                            Text("Carico l'ortofoto…")
                                .font(Theme.Typo.caption())
                                .foregroundStyle(EditorTheme.testoMuto)
                        }
                        Button("Chiudi") { onChiudi() }
                            .foregroundStyle(EditorTheme.accento)
                    }
                }
            }
        }
        .task(id: url) { await carica() }
    }

    private func carica() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let ui = UIImage(data: data) else {
                errore = "decode immagine fallito"
                return
            }
            immagine = ui
        } catch {
            self.errore = error.localizedDescription
        }
    }
}

// MARK: – Preview (ortofoto procedurale, nessun asset pesante)

#Preview {
    // Facciata demo 2268×1936 px @ 110 px/m (~20.6×17.6 m), generata a runtime
    MarcaturaFacciataView(immagine: .facciataDemo(), ppm: 110)
}

private extension UIImage {
    /// Ortofoto di prova: intonaco + griglia di finestre + porta + zoccolo.
    static func facciataDemo() -> UIImage {
        let size = CGSize(width: 2268, height: 1936)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Intonaco
            cg.setFillColor(UIColor(red: 0.86, green: 0.80, blue: 0.68, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Zoccolo
            cg.setFillColor(UIColor(white: 0.45, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: size.height - 180, width: size.width, height: 180))
            // Finestre 4×3
            cg.setFillColor(UIColor(red: 0.18, green: 0.24, blue: 0.32, alpha: 1).cgColor)
            for riga in 0..<3 {
                for col in 0..<4 {
                    let r = CGRect(x: 220 + CGFloat(col) * 500,
                                   y: 220 + CGFloat(riga) * 480,
                                   width: 280, height: 330)
                    cg.fill(r)
                    cg.setStrokeColor(UIColor(white: 0.95, alpha: 1).cgColor)
                    cg.setLineWidth(14)
                    cg.stroke(r.insetBy(dx: -10, dy: -10))
                    cg.setFillColor(UIColor(red: 0.18, green: 0.24, blue: 0.32, alpha: 1).cgColor)
                }
            }
            // Porta
            cg.setFillColor(UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 1).cgColor)
            cg.fill(CGRect(x: 1020, y: size.height - 180 - 460, width: 240, height: 460))
            // Crepa diagonale (zona "da rifare" plausibile)
            cg.setStrokeColor(UIColor(white: 0.35, alpha: 0.8).cgColor)
            cg.setLineWidth(6)
            cg.move(to: CGPoint(x: 1700, y: 300))
            cg.addLine(to: CGPoint(x: 1950, y: 720))
            cg.addLine(to: CGPoint(x: 1880, y: 1050))
            cg.strokePath()
        }
    }
}

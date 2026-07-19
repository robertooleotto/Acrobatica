import SwiftUI
import MapKit
import CoreLocation

/// Livello edificio: aggrega facciate, lavorazioni, squadra e preventivo.
struct DettaglioCantiereView: View {
    @ObservedObject var cantiere: Cantiere
    @EnvironmentObject private var app: AppState

    @State private var rilievoInCattura: Rilievo?
    @State private var coverURL: URL?
    @State private var showEditor3D = false
    @State private var showRilevamento = false
    @State private var showComputo = false
    @State private var showFiniture = false
    @State private var showPianificazione = false
    @State private var preventivoCreato: Preventivo?

    private var rilievoOperativo: Rilievo? {
        cantiere.rilievi.first { $0.sessionId != nil }
    }

    private var ultimoPreventivo: Preventivo? {
        app.preventivi.first { $0.cantiereNome == cantiere.nome }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                copertina
                intestazione
                metriche
                riepilogoOperativo
                azioniEdificio
                facciateSection
            }
            .padding(.bottom, 36)
        }
        .background(Theme.paper)
        .navigationTitle(cantiere.nome)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { iniziaNuovoRilievo() } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Nuova acquisizione")
            }
        }
        .task(id: cantiere.id) { await caricaCopertina() }
        .fullScreenCover(item: $rilievoInCattura) { rilievo in
            CatturaARView(
                rilievo: rilievo,
                onCompletato: { rilievoInCattura = nil },
                onAnnulla: { rilievoInCattura = nil })
        }
        .fullScreenCover(isPresented: $showEditor3D) {
            if let sessionId = rilievoOperativo?.sessionId {
                EditorMesh3DCaricamentoView(
                    sessionId: sessionId,
                    onChiudi: { showEditor3D = false })
            }
        }
        .fullScreenCover(isPresented: $showRilevamento) {
            if let sessionId = rilievoOperativo?.sessionId {
                ComputoMetricoView(
                    sessionId: sessionId,
                    avviaRilevamentoAutomatico: true,
                    onChiudi: { showRilevamento = false },
                    onMetricheAggiornate: aggiornaMetricheOperative)
            }
        }
        .fullScreenCover(isPresented: $showComputo) {
            if let sessionId = rilievoOperativo?.sessionId {
                ComputoMetricoView(
                    sessionId: sessionId,
                    onChiudi: { showComputo = false },
                    onMetricheAggiornate: aggiornaMetricheOperative)
            }
        }
        .fullScreenCover(isPresented: $showFiniture) {
            ProposteFinituraView(
                referenceURL: coverURL,
                onChiudi: { showFiniture = false },
                onConferma: { scelta in
                    cantiere.finitureScelte = [scelta]
                })
        }
        .sheet(isPresented: $showPianificazione) {
            PianificazioneEdificioView(cantiere: cantiere)
        }
        .navigationDestination(isPresented: Binding(
            get: { preventivoCreato != nil },
            set: { if !$0 { preventivoCreato = nil } }
        )) {
            if let preventivoCreato {
                AnteprimaPreventivoView(preventivo: preventivoCreato)
            }
        }
    }

    private var copertina: some View {
        Group {
            if let coverURL {
                EdificioRemoteImage(url: coverURL)
            } else {
                ZStack {
                    Theme.grayBg
                    Image(systemName: "building.2")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.muted)
                }
                .frame(height: 230)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .clipped()
    }

    private var intestazione: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(cantiere.nome)
                    .font(Theme.Typo.title(24, .bold))
                    .foregroundStyle(Theme.navy)
                Text(cantiere.cliente)
                    .font(Theme.Typo.body(14, .semibold))
                    .foregroundStyle(Theme.muted)
                if !cantiere.indirizzo.isEmpty {
                    Label(cantiere.indirizzo, systemImage: "mappin.and.ellipse")
                        .font(Theme.Typo.caption(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            EdificioMapPreview(indirizzo: cantiere.indirizzo)
                .frame(width: 116, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair2))
        }
        .padding(.horizontal, 16)
    }

    private var metriche: some View {
        HStack(spacing: 10) {
            MetricCard(label: "Area lorda", value: area(cantiere.areaLordaTotale))
            MetricCard(label: "Area netta", value: area(cantiere.areaNettaTotale), highlight: true)
            MetricCard(
                label: "Preventivo",
                value: ultimoPreventivo.map { totaleCompatto($0.totale) } ?? "—")
        }
        .padding(.horizontal, 16)
    }

    private var riepilogoOperativo: some View {
        VStack(spacing: 0) {
            rigaRiepilogo(
                icona: "paintbrush.pointed.fill",
                titolo: "Finiture",
                valore: cantiere.finitureScelte.isEmpty
                    ? "Non definite" : cantiere.finitureScelte.joined(separator: ", "))
            Divider().padding(.leading, 48)
            Button { showPianificazione = true } label: {
                rigaRiepilogo(
                    icona: "person.2.fill",
                    titolo: "Squadra",
                    valore: cantiere.squadra.isEmpty
                        ? "Da assegnare"
                        : "\(cantiere.squadra.count) persone · \(cantiere.squadra.joined(separator: ", "))",
                    mostraFreccia: true)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 48)
            Button { showPianificazione = true } label: {
                rigaRiepilogo(
                    icona: "clock.fill",
                    titolo: "Ore programmate",
                    valore: cantiere.oreProgrammate > 0
                        ? String(format: "%.0f ore", cantiere.oreProgrammate) : "Da pianificare",
                    mostraFreccia: true)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.white)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rigaRiepilogo(
        icona: String,
        titolo: String,
        valore: String,
        mostraFreccia: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icona)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.navy)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(titolo)
                    .font(Theme.Typo.caption(11, .semibold))
                    .foregroundStyle(Theme.muted)
                Text(valore)
                    .font(Theme.Typo.body(14, .semibold))
                    .foregroundStyle(Theme.navy)
                    .lineLimit(2)
            }
            Spacer()
            if mostraFreccia {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }

    private var azioniEdificio: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edificio")
                .font(Theme.Typo.title(17))
                .foregroundStyle(Theme.navy)

            BrandButton(title: "Editor 3D", systemImage: "cube.transparent", kind: .secondary) {
                showEditor3D = true
            }
            .disabled(rilievoOperativo == nil)

            BrandButton(title: "Rileva e segna zone", systemImage: "viewfinder", kind: .secondary) {
                showRilevamento = true
            }
            .disabled(rilievoOperativo == nil)

            BrandButton(title: "Computo metrico", systemImage: "ruler", kind: .secondary) {
                showComputo = true
            }
            .disabled(rilievoOperativo == nil)

            BrandButton(title: "Simula finitura", systemImage: "paintbrush.pointed.fill", kind: .secondary) {
                showFiniture = true
            }
            .disabled(coverURL == nil)

            BrandButton(title: "Genera preventivo", systemImage: "doc.text.fill", kind: .primary) {
                creaPreventivoEdificio()
            }
        }
        .padding(.horizontal, 16)
    }

    private var facciateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Facciate")
                    .font(Theme.Typo.title(17))
                    .foregroundStyle(Theme.navy)
                Spacer()
                Text("\(cantiere.rilievi.count)")
                    .font(Theme.Typo.caption())
                    .foregroundStyle(Theme.muted)
            }

            if cantiere.rilievi.isEmpty {
                EmptyStateView(
                    systemImage: "viewfinder",
                    title: "Nessuna facciata",
                    subtitle: "Avvia un'acquisizione per costruire il modello dell'edificio.",
                    cta: "Nuova acquisizione",
                    onCta: iniziaNuovoRilievo)
            } else {
                ForEach(cantiere.rilievi) { rilievo in
                    NavigationLink {
                        RisultatoPanoramaView(rilievo: rilievo)
                    } label: {
                        rilievoRow(rilievo)
                    }
                    .buttonStyle(.plain)
                }
                BrandButton(title: "Nuova acquisizione", systemImage: "plus", kind: .secondary) {
                    iniziaNuovoRilievo()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func rilievoRow(_ rilievo: Rilievo) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "rectangle.portrait.on.rectangle.portrait", size: 48, glyph: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(rilievo.nomeOrientato)
                    .font(Theme.Typo.title(15, .semibold))
                    .foregroundStyle(Theme.navy)
                HStack(spacing: 6) {
                    StatoChip(text: rilievo.stato.rawValue, tint: rilievo.stato.tint)
                    if rilievo.areaNetta > 0 {
                        Text(String(format: "%.1f m²", rilievo.areaNetta))
                            .font(Theme.Typo.caption(11))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer()
            Menu {
                ForEach(OrientamentoFacciata.allCases) { orientamento in
                    Button {
                        rilievo.orientamentoManuale = orientamento
                    } label: {
                        Label(orientamento.rawValue,
                              systemImage: rilievo.orientamento == orientamento
                                ? "checkmark" : "location.north")
                    }
                }
            } label: {
                Image(systemName: "location.north.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.navy)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Orientamento facciata")
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
    }

    @MainActor
    private func caricaCopertina() async {
        var candidata = cantiere.rilievi.compactMap(\.panoramaUrl).first
        for rilievo in cantiere.rilievi {
            guard let sessionId = rilievo.sessionId else { continue }
            guard let result = try? await BackendAPIClient.shared.projectionStatus(sessionId: sessionId),
                  result.state == "complete" else {
                continue
            }
            rilievo.areaLorda = result.total_area_m2
            if let aperture = try? await BackendAPIClient.shared.openingStatus(sessionId: sessionId),
               aperture.state == "complete" {
                rilievo.areaNetta = aperture.net_area_m2
            } else if rilievo.areaNetta == 0 {
                rilievo.areaNetta = result.total_area_m2
            }
            guard candidata == nil,
                  let piano = result.planes?.max(by: { $0.area_m2 < $1.area_m2 }) else {
                continue
            }
            let nome = URL(fileURLWithPath: piano.file).lastPathComponent
            guard let file = result.files.first(where: {
                $0.name == piano.file || URL(fileURLWithPath: $0.name).lastPathComponent == nome
            }), let url = URL(string: file.url) else { continue }
            candidata = url
            rilievo.panoramaUrl = url
        }
        coverURL = candidata
    }

    private func aggiornaMetricheOperative(_ lorda: Double, _ netta: Double) {
        rilievoOperativo?.areaLorda = lorda
        rilievoOperativo?.areaNetta = netta
    }

    private func iniziaNuovoRilievo() {
        let rilievo = Rilievo(nome: "Facciata da orientare", stato: .inCattura)
        cantiere.rilievi.append(rilievo)
        rilievoInCattura = rilievo
    }

    private func creaPreventivoEdificio() {
        let quantita = max(cantiere.areaNettaTotale, 1)
        let finitura = cantiere.finitureScelte.first ?? "Finitura intonaco"
        let preventivo = Preventivo(
            numero: app.nuovoNumeroPreventivo(),
            clienteNome: cantiere.cliente,
            cantiereNome: cantiere.nome,
            voci: [
                VoceLavoro(
                    descrizione: finitura,
                    quantita: quantita,
                    unita: "m²",
                    prezzoUnitario: 18)
            ],
            manodoperaOre: cantiere.oreProgrammate,
            tariffaOraria: app.tariffaOrariaDefault,
            ivaPct: app.ivaDefault)
        app.preventivi.insert(preventivo, at: 0)
        preventivoCreato = preventivo
    }

    private func area(_ valore: Double) -> String {
        valore > 0 ? String(format: "%.1f m²", valore) : "—"
    }

    private func totaleCompatto(_ valore: Double) -> String {
        valore >= 1000 ? String(format: "€ %.0fk", valore / 1000) : String(format: "€ %.0f", valore)
    }
}

struct StatoChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct EdificioRemoteImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().tint(Theme.navy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.grayBg)
        .task(id: url) {
            var data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else if let response = try? await URLSession.shared.data(from: url) {
                data = response.0
            }
            if let data, let loaded = UIImage(data: data) {
                image = loaded
            }
        }
    }
}

private struct EdificioMapPreview: View {
    let indirizzo: String
    @State private var snapshot: UIImage?

    var body: some View {
        ZStack {
            Theme.grayBg
            if let snapshot {
                Image(uiImage: snapshot).resizable().scaledToFill()
            } else {
                Image(systemName: "map.fill")
                    .foregroundStyle(Theme.muted)
            }
        }
        .task(id: indirizzo) { await generaSnapshot() }
        .allowsHitTesting(false)
    }

    private func generaSnapshot() async {
        guard !indirizzo.isEmpty,
              let placemark = try? await CLGeocoder().geocodeAddressString(indirizzo).first,
              let coordinate = placemark.location?.coordinate else { return }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 650,
            longitudinalMeters: 650)
        options.size = CGSize(width: 232, height: 184)
        options.scale = UIScreen.main.scale
        if let result = try? await MKMapSnapshotter(options: options).start() {
            snapshot = result.image
        }
    }
}

private struct PianificazioneEdificioView: View {
    @ObservedObject var cantiere: Cantiere
    @Environment(\.dismiss) private var dismiss
    @State private var nuovoNome = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Squadra") {
                    ForEach(cantiere.squadra, id: \.self) { nome in
                        HStack {
                            Label(nome, systemImage: "person.fill")
                            Spacer()
                            Button(role: .destructive) {
                                cantiere.squadra.removeAll { $0 == nome }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    HStack {
                        TextField("Nome operatore", text: $nuovoNome)
                        Button {
                            let nome = nuovoNome.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !nome.isEmpty else { return }
                            cantiere.squadra.append(nome)
                            nuovoNome = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(nuovoNome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Programmazione") {
                    Stepper(value: $cantiere.oreProgrammate, in: 0...10_000, step: 8) {
                        LabeledContent(
                            "Ore previste",
                            value: String(format: "%.0f h", cantiere.oreProgrammate))
                    }
                }
            }
            .navigationTitle("Squadra e ore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI
import AppKit

private let compositingRoot = URL(fileURLWithPath: "/Users/liscio/Acrobatica")
private let compositingDefaultInput = compositingRoot
    .appendingPathComponent("exports/oc_texture_registration_local/input")
private let compositingDefaultPhotos = compositingRoot
    .appendingPathComponent("backend/data/fixtures/6cdcb8ff/photos")
private let compositingDefaultOutput = compositingRoot
    .appendingPathComponent("exports/oc_texture_registration_local/output")

private func processErrorText(stderr: String, stdout: String) -> String {
    let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? stdout : stderr
    let lines = source.split(whereSeparator: \.isNewline)
    return lines.suffix(14).joined(separator: "\n")
}

private struct CompositingPlaneDocument: Decodable {
    let planes: [CompositingPlaneOption]
}

struct CompositingPlaneOption: Decodable, Identifiable {
    let id: Int
    let nome: String
}

struct CompositingReport: Decodable {
    let planeId: Int
    let planeName: String
    let sizePx: [Int]
    let acceptedPhotos: Int
    let registeredPlanarCoverage: Double
    let globalAlignment: CompositingGlobalAlignment?
    let photos: [CompositingPhotoReport]
}

struct CompositingGlobalAlignment: Decodable {
    let applied: Bool
    let reason: String
    let pairsAccepted: Int?
    let matchedPoints: Int?
    let medianPairErrorBeforePx: Double?
    let medianPairErrorAfterPx: Double?
}

struct CompositingPhotoReport: Decodable, Identifiable {
    let rank: Int
    let key: String
    let score: Double
    let coverage: Double
    let photoFound: Bool
    let registration: CompositingRegistration?

    var id: String { key }
}

struct CompositingRegistration: Decodable {
    let accepted: Bool
    let reason: String
    let inliers: Int?
    let inlierRatio: Double?
    let scale: Double?
    let rotationDeg: Double?
    let shiftPx: Double?
    let maxDisplacementPx: Double?
    let medianPriorErrorPx: Double?
    let medianResidualPx: Double?
    let matrix: [[Double]]?
    let globalCorrection: CompositingGlobalCorrection?
}

struct CompositingGlobalCorrection: Codable {
    let offsetX: Double
    let offsetY: Double
    let rotationDeg: Double
    let scale: Double
    let matrix: [[Double]]
}

struct ManualPhotoCorrection: Codable {
    var enabled: Bool
    var offsetX: Double
    var offsetY: Double
    var rotationDeg: Double
    var scale: Double

    static let identity = ManualPhotoCorrection(
        enabled: true, offsetX: 0, offsetY: 0, rotationDeg: 0, scale: 1
    )
}

private struct CompositingAdjustmentsDocument: Codable {
    let schema: String
    let planeId: Int
    let planeName: String
    let outputSizePx: [Int]
    let photos: [CompositingAdjustmentEntry]
}

private struct CompositingAdjustmentEntry: Codable {
    let photoId: String
    let automaticMatrix: [[Double]]
    let automaticAccepted: Bool
    let globalCorrection: CompositingGlobalCorrection?
    let manual: ManualPhotoCorrection
}

enum CompositingCanvasMode: String, CaseIterable, Identifiable {
    case reference = "OC"
    case before = "Posa"
    case adjust = "Regola"
    case blend = "Blend"
    case best = "Best"

    var id: String { rawValue }
}

@MainActor
final class CompositingWorkspaceModel: ObservableObject {
    @Published var inputDirectory = compositingDefaultInput
    @Published var photosDirectory = compositingDefaultPhotos
    @Published var outputDirectory = compositingDefaultOutput
    @Published var planeOptions: [CompositingPlaneOption] = []
    @Published var planeID = 4
    @Published var texelMM = 20.0
    @Published var maxPhotos = 20
    @Published var isRunning = false
    @Published var status = "Pronto"
    @Published var error: String?
    @Published var report: CompositingReport?
    @Published var selectedPhotoKey: String?
    @Published var canvasMode: CompositingCanvasMode = .adjust
    @Published var overlayOpacity = 0.5
    @Published var manualOffsetX = 0.0
    @Published var manualOffsetY = 0.0
    @Published var manualRotationDeg = 0.0
    @Published var manualScale = 1.0
    @Published var manualEnabled = true

    private var corrections: [String: ManualPhotoCorrection] = [:]
    private var imageCache: [String: NSImage] = [:]

    var selectedPhoto: CompositingPhotoReport? {
        guard let key = selectedPhotoKey else { return nil }
        return report?.photos.first { $0.key == key }
    }

    var outputPixelSize: CGSize {
        guard let size = report?.sizePx, size.count == 2 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: max(size[0], 1), height: max(size[1], 1))
    }

    init() {
        loadPlaneOptions()
    }

    func loadPlaneOptions() {
        let url = inputDirectory.appendingPathComponent("planes.json")
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(CompositingPlaneDocument.self, from: data)
        else {
            planeOptions = []
            return
        }
        planeOptions = document.planes
        if !planeOptions.contains(where: { $0.id == planeID }), let first = planeOptions.first {
            planeID = first.id
        }
    }

    func chooseInputDirectory() {
        guard let url = chooseDirectory(title: "Cartella input compositing", initial: inputDirectory) else { return }
        inputDirectory = url
        loadPlaneOptions()
    }

    func choosePhotosDirectory() {
        guard let url = chooseDirectory(title: "Cartella fotografie", initial: photosDirectory) else { return }
        photosDirectory = url
    }

    func chooseOutputDirectory() {
        guard let url = chooseDirectory(title: "Cartella output", initial: outputDirectory) else { return }
        outputDirectory = url
        loadExistingReport()
    }

    private func chooseDirectory(title: String, initial: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = initial
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(outputDirectory)
    }

    func runPipeline() {
        guard !isRunning else { return }
        saveCurrentCorrection()
        error = nil
        isRunning = true
        status = "Calcolo riferimento OC e registrazione..."

        let executable = compositingRoot.appendingPathComponent("backend/venv/bin/python")
        let backend = compositingRoot.appendingPathComponent("backend")
        let mesh = inputDirectory.appendingPathComponent("model_nobbox.obj")
        let mtl = inputDirectory.appendingPathComponent("model_nobbox.mtl")
        let planes = inputDirectory.appendingPathComponent("planes.json")
        let poses = inputDirectory.appendingPathComponent("oc_poses.json")
        let photos = photosDirectory
        let output = outputDirectory
        let plane = planeID
        let texel = texelMM
        let count = maxPhotos

        let required = [executable, mesh, mtl, planes, poses, photos]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            isRunning = false
            error = "Input mancanti. Controlla mesh, MTL, planes.json, pose e foto."
            return
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = executable
            process.currentDirectoryURL = backend
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.arguments = [
                "-m", "scripts.run_oc_reference_registration_local",
                "--mesh", mesh.path,
                "--mtl", mtl.path,
                "--planes", planes.path,
                "--poses", poses.path,
                "--photos", photos.path,
                "--out", output.path,
                "--plane-id", String(plane),
                "--texel-mm", String(texel),
                "--max-photos", String(count),
                "--coverage-photos", "60",
            ]
            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                DispatchQueue.main.async {
                    self.isRunning = false
                    if process.terminationStatus == 0 {
                        self.status = "Registrazione completata"
                        self.loadExistingReport()
                    } else {
                        let detail = processErrorText(stderr: stderr, stdout: stdout)
                        self.error = detail.isEmpty ? "Runner terminato con errore" : detail
                        self.status = "Registrazione non riuscita"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.error = error.localizedDescription
                    self.status = "Registrazione non riuscita"
                }
            }
        }
    }

    func loadExistingReport() {
        let url = outputDirectory.appendingPathComponent("report.json")
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(CompositingReport.self, from: data)
            report = decoded
            imageCache.removeAll()
            corrections = decoded.photos.reduce(into: [:]) { values, photo in
                values[photo.key] = ManualPhotoCorrection(
                    enabled: photo.registration?.accepted ?? false,
                    offsetX: 0, offsetY: 0, rotationDeg: 0, scale: 1
                )
            }
            loadSavedAdjustments()
            let first = decoded.photos.first(where: { $0.photoFound })?.key
            selectPhoto(selectedPhotoKey.flatMap { key in
                decoded.photos.contains(where: { $0.key == key }) ? key : nil
            } ?? first)
            status = "\(decoded.acceptedPhotos) foto · copertura \(Int(decoded.registeredPlanarCoverage * 100))%"
            if let global = decoded.globalAlignment,
               global.applied,
               let before = global.medianPairErrorBeforePx,
               let after = global.medianPairErrorAfterPx {
                status = String(
                    format: "%d foto · globale %.2f→%.2f px · copertura %d%%",
                    decoded.acceptedPhotos, before, after,
                    Int(decoded.registeredPlanarCoverage * 100)
                )
            }
            error = nil
        } catch {
            report = nil
            self.error = "Report non leggibile: \(error.localizedDescription)"
        }
    }

    func selectPhoto(_ key: String?) {
        saveCurrentCorrection()
        selectedPhotoKey = key
        guard let key else { return }
        let value = corrections[key] ?? .identity
        manualEnabled = value.enabled
        manualOffsetX = value.offsetX
        manualOffsetY = value.offsetY
        manualRotationDeg = value.rotationDeg
        manualScale = value.scale
    }

    func saveCurrentCorrection() {
        guard let key = selectedPhotoKey else { return }
        corrections[key] = ManualPhotoCorrection(
            enabled: manualEnabled,
            offsetX: manualOffsetX,
            offsetY: manualOffsetY,
            rotationDeg: manualRotationDeg,
            scale: manualScale
        )
    }

    func resetCurrentCorrection() {
        guard let key = selectedPhotoKey else { return }
        let automaticAccepted = selectedPhoto?.registration?.accepted ?? false
        corrections[key] = ManualPhotoCorrection(
            enabled: automaticAccepted, offsetX: 0, offsetY: 0, rotationDeg: 0, scale: 1
        )
        selectPhoto(key)
    }

    func exportAdjustments() {
        guard !isRunning else { return }
        saveCurrentCorrection()
        guard let report else { return }
        let entries = report.photos.map { photo in
            CompositingAdjustmentEntry(
                photoId: photo.key,
                automaticMatrix: photo.registration?.matrix ?? [[1, 0, 0], [0, 1, 0]],
                automaticAccepted: photo.registration?.accepted ?? false,
                globalCorrection: photo.registration?.globalCorrection,
                manual: corrections[photo.key] ?? .identity
            )
        }
        let document = CompositingAdjustmentsDocument(
            schema: "acro.compositing-adjustments/v1",
            planeId: report.planeId,
            planeName: report.planeName,
            outputSizePx: report.sizePx,
            photos: entries
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(document)
            try data.write(to: outputDirectory.appendingPathComponent("compositing_adjustments.json"), options: .atomic)
            recomposeOutput()
        } catch {
            self.error = "Salvataggio fallito: \(error.localizedDescription)"
        }
    }

    private func recomposeOutput() {
        let executable = compositingRoot.appendingPathComponent("backend/venv/bin/python")
        let backend = compositingRoot.appendingPathComponent("backend")
        let output = outputDirectory
        guard FileManager.default.fileExists(atPath: executable.path) else {
            error = "Python locale non trovato: \(executable.path)"
            return
        }

        isRunning = true
        error = nil
        status = "Ricompongo Blend e Best..."
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.currentDirectoryURL = backend
            process.standardOutput = pipe
            process.standardError = pipe
            process.arguments = [
                "-m", "scripts.recompose_oc_registration_local",
                "--output", output.path,
            ]
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let log = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.isRunning = false
                    if process.terminationStatus == 0 {
                        self.imageCache.removeAll()
                        self.canvasMode = .best
                        self.status = "Correzioni applicate a Blend e Best"
                    } else {
                        self.error = log.isEmpty ? "Ricomposizione terminata con errore" : log
                        self.status = "Correzioni salvate, ricomposizione non riuscita"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.error = error.localizedDescription
                    self.status = "Correzioni salvate, ricomposizione non riuscita"
                }
            }
        }
    }

    private func loadSavedAdjustments() {
        let url = outputDirectory.appendingPathComponent("compositing_adjustments.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let document = try? decoder.decode(CompositingAdjustmentsDocument.self, from: data),
              document.planeId == report?.planeId,
              document.outputSizePx == report?.sizePx else { return }
        for entry in document.photos {
            corrections[entry.photoId] = entry.manual
        }
    }

    func image(_ name: String) -> NSImage? {
        let url = outputDirectory.appendingPathComponent(name)
        if let cached = imageCache[url.path] { return cached }
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        imageCache[url.path] = loaded
        return loaded
    }

    func selectedStem() -> String? {
        guard let photo = selectedPhoto, let id = Int(photo.key) else { return nil }
        return String(format: "photo_%02d_%04d", photo.rank, id)
    }
}

struct CompositingWorkspaceView: View {
    @StateObject private var model = CompositingWorkspaceModel()

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            CompositingCanvasView(model: model)
                .frame(minWidth: 560)
            inspector
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("report.json").path) {
                model.loadExistingReport()
            }
        }
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.chooseInputDirectory() } label: {
                    Label("Input", systemImage: "folder")
                }
                Button { model.choosePhotosDirectory() } label: {
                    Label("Foto", systemImage: "photo.on.rectangle")
                }
                Button { model.chooseOutputDirectory() } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .help("Cartella output")
            }

            if !model.planeOptions.isEmpty {
                Picker("Piano", selection: $model.planeID) {
                    ForEach(model.planeOptions) { plane in
                        Text("\(plane.id) · \(plane.nome)").tag(plane.id)
                    }
                }
            }

            HStack {
                Text("Risoluzione")
                Slider(value: $model.texelMM, in: 8...30, step: 1)
                Text("\(Int(model.texelMM)) mm")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            Stepper("Foto allineate: \(model.maxPhotos)", value: $model.maxPhotos, in: 1...60)

            HStack {
                Button { model.runPipeline() } label: {
                    Label(model.isRunning ? "Calcolo" : "Esegui", systemImage: model.isRunning ? "hourglass" : "play.fill")
                }
                .disabled(model.isRunning)
                Button { model.loadExistingReport() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Ricarica report")
                Button { model.openOutputDirectory() } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("Apri output")
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let error = model.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(5)
            }

            Divider()

            List(selection: Binding(
                get: { model.selectedPhotoKey },
                set: { model.selectPhoto($0) }
            )) {
                ForEach(model.report?.photos ?? []) { photo in
                    HStack(spacing: 8) {
                        Image(systemName: (photo.registration?.accepted ?? false) ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle((photo.registration?.accepted ?? false) ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%04d", Int(photo.key) ?? 0))
                                .monospacedDigit()
                            Text(String(format: "cop. %.0f%% · err. %.2f px",
                                        photo.coverage * 100,
                                        photo.registration?.medianResidualPx ?? 0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(photo.key)
                }
            }
        }
        .padding(12)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Micro-correzione")
                    .font(.headline)

                if let photo = model.selectedPhoto, let registration = photo.registration {
                    HStack {
                        Text(String(format: "Foto %04d", Int(photo.key) ?? 0))
                            .font(.title3)
                        Spacer()
                        Toggle("", isOn: $model.manualEnabled)
                            .labelsHidden()
                            .onChange(of: model.manualEnabled) { _ in model.saveCurrentCorrection() }
                    }

                    metric("Inlier", "\(registration.inliers ?? 0)")
                    metric("Rapporto", String(format: "%.0f%%", (registration.inlierRatio ?? 0) * 100))
                    metric("Residuo", String(format: "%.2f px", registration.medianResidualPx ?? 0))
                    metric("Spostamento", String(format: "%.1f px", registration.maxDisplacementPx ?? 0))
                    if let global = registration.globalCorrection {
                        metric("Globale X/Y", String(
                            format: "%+.1f / %+.1f px", global.offsetX, global.offsetY
                        ))
                        metric("Globale rot.", String(format: "%+.2f°", global.rotationDeg))
                        metric("Globale scala", String(format: "%.3f×", global.scale))
                    }

                    Divider()

                    adjustmentSlider("X", value: $model.manualOffsetX, range: -40...40, step: 0.5, suffix: "px")
                    adjustmentSlider("Y", value: $model.manualOffsetY, range: -40...40, step: 0.5, suffix: "px")
                    adjustmentSlider("Rotazione", value: $model.manualRotationDeg, range: -0.5...0.5, step: 0.01, suffix: "°")
                    adjustmentSlider("Scala", value: $model.manualScale, range: 0.97...1.03, step: 0.001, suffix: "×")

                    HStack {
                        Button { model.resetCurrentCorrection() } label: {
                            Label("Ripristina", systemImage: "arrow.uturn.backward")
                        }
                        Button { model.exportAdjustments() } label: {
                            Label("Salva", systemImage: "square.and.arrow.down")
                        }
                        .disabled(model.isRunning)
                    }
                } else {
                    Text("Nessuna foto selezionata")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func adjustmentSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(formatted(value.wrappedValue, suffix: suffix))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { _ in model.saveCurrentCorrection() }
        }
    }

    private func formatted(_ value: Double, suffix: String) -> String {
        switch suffix {
        case "px": return String(format: "%+.1f %@", value, suffix)
        case "°": return String(format: "%+.2f%@", value, suffix)
        default: return String(format: "%.3f%@", value, suffix)
        }
    }
}

struct CompositingCanvasView: View {
    @ObservedObject var model: CompositingWorkspaceModel
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Vista", selection: $model.canvasMode) {
                    ForEach(CompositingCanvasMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if model.canvasMode == .adjust {
                    Slider(value: $model.overlayOpacity, in: 0...1, step: 0.05)
                        .frame(width: 140)
                        .help("Opacità fotografia")
                }
            }
            .padding(10)

            Divider()

            GeometryReader { proxy in
                let pixelSize = model.outputPixelSize
                let fitScale = min(
                    proxy.size.width / max(pixelSize.width, 1),
                    proxy.size.height / max(pixelSize.height, 1)
                )
                let fitted = CGSize(width: pixelSize.width * fitScale, height: pixelSize.height * fitScale)

                ZStack {
                    Color.black
                    canvasContent(size: fitted, fitScale: fitScale)
                        .frame(width: fitted.width, height: fitted.height)
                        .clipped()
                }
                .contentShape(Rectangle())
                .gesture(adjustmentDrag(fitScale: fitScale))
            }
        }
    }

    @ViewBuilder
    private func canvasContent(size: CGSize, fitScale: CGFloat) -> some View {
        switch model.canvasMode {
        case .reference:
            singleImage("01_oc_reference.png", size: size)
        case .before:
            if let stem = model.selectedStem() {
                singleImage("\(stem)_overlay_before.png", size: size)
            }
        case .blend:
            singleImage("03_registered_mosaic_blend.png", size: size)
        case .best:
            singleImage("04_registered_best_view.png", size: size)
        case .adjust:
            ZStack {
                singleImage("01_oc_reference.png", size: size)
                if model.manualEnabled,
                   let stem = model.selectedStem(),
                   let aligned = model.image("\(stem)_aligned.png"),
                   let mask = model.image("\(stem)_aligned_mask.png") {
                    Image(nsImage: aligned)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .mask(
                            Image(nsImage: mask)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                                .luminanceToAlpha()
                        )
                        .scaleEffect(model.manualScale)
                        .rotationEffect(.degrees(model.manualRotationDeg))
                        .offset(
                            x: model.manualOffsetX * fitScale,
                            y: model.manualOffsetY * fitScale
                        )
                        .opacity(model.overlayOpacity)
                }
            }
        }
    }

    @ViewBuilder
    private func singleImage(_ name: String, size: CGSize) -> some View {
        if let image = model.image(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                Color.black
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func adjustmentDrag(fitScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard model.canvasMode == .adjust, fitScale > 0 else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: model.manualOffsetX, y: model.manualOffsetY)
                }
                guard let start = dragStart else { return }
                model.manualOffsetX = min(max(start.x + value.translation.width / fitScale, -40), 40)
                model.manualOffsetY = min(max(start.y + value.translation.height / fitScale, -40), 40)
            }
            .onEnded { _ in
                dragStart = nil
                model.saveCurrentCorrection()
            }
    }
}

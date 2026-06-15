// HelloPhotogrammetry.swift
//
// Object Capture CLI per Acrobatica — genera una mesh ad alta densita' dalle
// foto della facciata su un Mac Apple Silicon potente (Mac Studio / mac2-m2pro).
//
// Compilazione (sul Mac affittato, Apple Silicon, macOS 13+):
//     swiftc -O HelloPhotogrammetry.swift -o hpg
//
// Uso:
//     ./hpg <cartella_foto> <output.usdz> [detail] [sampleOrdering] [featureSensitivity]
//   detail            = preview | reduced | medium | full | raw   (default: raw)
//   sampleOrdering    = unordered | sequential                    (default: unordered)
//   featureSensitivity= normal | high                             (default: high)
//
// Esempio (mesh massima densita'):
//     ./hpg ./photos ./model_raw.usdz raw unordered high
//
// Note:
// - .raw produce la geometria piu' densa e meno levigata (ideale per misurare
//   rilievi: cornici, balcone). .full e' levigata ma comunque molto piu' densa
//   dei 157k tri attuali.
// - Richiede Apple Silicon. Su Intel l'API esiste ma e' limitata/instabile.

import Foundation
import RealityKit
import os

@available(macOS 13.0, *)
struct Runner {
    let inputFolder: URL
    let outputFile: URL
    let detail: PhotogrammetrySession.Request.Detail
    let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering
    let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity

    func run() async throws {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = sampleOrdering
        configuration.featureSensitivity = featureSensitivity

        print("== Object Capture ==")
        print("  input:   \(inputFolder.path)")
        print("  output:  \(outputFile.path)")
        print("  detail:  \(detail)")
        print("  ordering:\(sampleOrdering)  sensitivity:\(featureSensitivity)")

        let session = try PhotogrammetrySession(input: inputFolder,
                                                configuration: configuration)

        let request = PhotogrammetrySession.Request.modelFile(url: outputFile,
                                                              detail: detail)
        try session.process(requests: [request])

        for try await output in session.outputs {
            switch output {
            case .processingComplete:
                print("\n[OK] processing complete")
                return
            case .requestError(let request, let error):
                print("\n[ERROR] request \(String(describing: request)): \(error)")
                throw error
            case .requestComplete(_, let result):
                if case .modelFile(let url) = result {
                    print("\n[OK] model written: \(url.path)")
                }
            case .requestProgress(_, let fraction):
                let pct = Int(fraction * 100)
                print("\r  progress: \(pct)%", terminator: "")
                fflush(stdout)
            case .inputComplete:
                print("  input ingested, reconstructing...")
            case .invalidSample(let id, let reason):
                print("  invalid sample \(id): \(reason)")
            case .skippedSample(let id):
                print("  skipped sample \(id)")
            case .automaticDownsampling:
                print("  [warn] automatic downsampling (poca RAM/VRAM?)")
            case .processingCancelled:
                print("  processing cancelled")
                return
            default:
                print("  output: \(output)")
            }
        }
    }
}

@available(macOS 13.0, *)
func parseDetail(_ s: String) -> PhotogrammetrySession.Request.Detail {
    switch s.lowercased() {
    case "preview": return .preview
    case "reduced": return .reduced
    case "medium":  return .medium
    case "full":    return .full
    case "raw":     return .raw
    default:        return .raw
    }
}

@available(macOS 13.0, *)
func parseOrdering(_ s: String) -> PhotogrammetrySession.Configuration.SampleOrdering {
    s.lowercased() == "sequential" ? .sequential : .unordered
}

@available(macOS 13.0, *)
func parseSensitivity(_ s: String) -> PhotogrammetrySession.Configuration.FeatureSensitivity {
    s.lowercased() == "high" ? .high : .normal
}

// --- entrypoint ---
guard #available(macOS 13.0, *) else {
    print("Richiede macOS 13.0+ su Apple Silicon.")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Uso: \(args[0]) <cartella_foto> <output.usdz> [detail] [ordering] [sensitivity]")
    exit(2)
}

let runner = Runner(
    inputFolder: URL(fileURLWithPath: args[1], isDirectory: true),
    outputFile: URL(fileURLWithPath: args[2]),
    detail: parseDetail(args.count > 3 ? args[3] : "raw"),
    sampleOrdering: parseOrdering(args.count > 4 ? args[4] : "unordered"),
    featureSensitivity: parseSensitivity(args.count > 5 ? args[5] : "high")
)

let sema = DispatchSemaphore(value: 0)
Task {
    do { try await runner.run() }
    catch { print("\n[FATAL] \(error)"); exit(1) }
    sema.signal()
}
sema.wait()
print("Fatto.")

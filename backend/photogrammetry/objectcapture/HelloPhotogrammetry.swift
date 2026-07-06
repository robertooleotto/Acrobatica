// HelloPhotogrammetry.swift
//
// Object Capture CLI per Acrobatica — genera mesh densa + POSE camera dalle foto
// della facciata, in UNA sola PhotogrammetrySession (mesh e pose nello stesso
// frame → proiezione 0px, niente Umeyama). Gira su Mac Apple Silicon (o su questo
// Intel con Radeon: ~10 min per ~90 foto a `.full`).
//
// Compilazione:
//     swiftc -O HelloPhotogrammetry.swift -o hpg
//
// Uso:
//     ./hpg <cartella_foto> <output.usdz> [detail] [sampleOrdering] [featureSensitivity]
//   detail            = preview | reduced | medium | full | raw   (default: full)
//   sampleOrdering    = unordered | sequential                    (default: sequential)
//   featureSensitivity= normal | high                             (default: high)
//
// Output: <output.usdz>  +  <output_dir>/oc_poses.json
//   oc_poses.json: { "<sampleIndex>": { rotation_wxyz:[w,x,y,z] (camera→world),
//                                        translation:[x,y,z] (centro camera C),
//                                        image:"NNNN.jpg" }, ... }
//   Le intrinseche (fx,fy,cx,cy) NON stanno nella Pose OC: si uniscono a valle
//   dalle pose ARKit della cattura (photos.json / camera_intrinsics).
//
// Config chiave (validata: proiezione 0px): ignoreBoundingBox=true,
// isObjectMaskingEnabled=false, `.modelFile + .poses` nella stessa sessione.

import Foundation
import RealityKit
import simd
import os

@available(macOS 14.0, *)
struct Runner {
    let inputFolder: URL
    let outputFile: URL
    let detail: PhotogrammetrySession.Request.Detail
    let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering
    let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity

    var posesFile: URL {
        outputFile.deletingLastPathComponent().appendingPathComponent("oc_poses.json")
    }

    func run() async throws {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = sampleOrdering
        configuration.featureSensitivity = featureSensitivity
        configuration.ignoreBoundingBox = true        // è una SCENA, non un oggetto
        configuration.isObjectMaskingEnabled = false

        print("== Object Capture (mesh + pose) ==")
        print("  input:   \(inputFolder.path)")
        print("  output:  \(outputFile.path)")
        print("  poses:   \(posesFile.path)")
        print("  detail:  \(detail)  ordering:\(sampleOrdering)  sensitivity:\(featureSensitivity)")

        let session = try PhotogrammetrySession(input: inputFolder,
                                                configuration: configuration)

        let requests: [PhotogrammetrySession.Request] = [
            .modelFile(url: outputFile, detail: detail),
            .poses,
        ]
        try session.process(requests: requests)

        for try await output in session.outputs {
            switch output {
            case .processingComplete:
                print("\n[OK] processing complete")
                return
            case .requestError(let request, let error):
                print("\n[ERROR] request \(String(describing: request)): \(error)")
                throw error
            case .requestComplete(_, let result):
                switch result {
                case .modelFile(let url):
                    print("\n[OK] model written: \(url.path)")
                case .poses(let poses):
                    try writePoses(poses)
                default:
                    break
                }
            case .requestProgress(_, let fraction):
                print("\r  progress: \(Int(fraction * 100))%", terminator: "")
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
                break
            }
        }
    }

    /// Serializza le pose OC (rotation_wxyz camera→world + translation centro C)
    /// nel formato consumato da project_photos_to_mesh.py e dal viewer.
    func writePoses(_ poses: PhotogrammetrySession.Poses) throws {
        var out: [String: [String: Any]] = [:]
        for (idx, pose) in poses.posesBySample {
            let q = pose.rotation          // simd_quatf: real = w, imag = (x,y,z)
            let t = pose.translation
            var rec: [String: Any] = [
                "rotation_wxyz": [Double(q.real), Double(q.imag.x), Double(q.imag.y), Double(q.imag.z)],
                "translation":   [Double(t.x), Double(t.y), Double(t.z)],
            ]
            if let url = poses.urlsBySample[idx] {
                rec["image"] = url.lastPathComponent
            }
            out[String(idx)] = rec
        }
        let data = try JSONSerialization.data(withJSONObject: out,
                                              options: [.sortedKeys, .prettyPrinted])
        try data.write(to: posesFile)
        print("\n[OK] poses written: \(posesFile.path)  (\(out.count) camere)")
    }
}

@available(macOS 14.0, *)
func parseDetail(_ s: String) -> PhotogrammetrySession.Request.Detail {
    switch s.lowercased() {
    case "preview": return .preview
    case "reduced": return .reduced
    case "medium":  return .medium
    case "full":    return .full
    case "raw":     return .raw
    default:        return .full
    }
}

@available(macOS 14.0, *)
func parseOrdering(_ s: String) -> PhotogrammetrySession.Configuration.SampleOrdering {
    s.lowercased() == "unordered" ? .unordered : .sequential
}

@available(macOS 14.0, *)
func parseSensitivity(_ s: String) -> PhotogrammetrySession.Configuration.FeatureSensitivity {
    s.lowercased() == "normal" ? .normal : .high
}

// --- entrypoint ---
guard #available(macOS 14.0, *) else {
    print("Richiede macOS 14.0+ (API .poses) su Apple Silicon o Mac con GPU discreta.")
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
    detail: parseDetail(args.count > 3 ? args[3] : "full"),
    sampleOrdering: parseOrdering(args.count > 4 ? args[4] : "sequential"),
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

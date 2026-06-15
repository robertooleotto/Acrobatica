// usdz2obj.swift
//
// Converte un .usdz di Object Capture in OBJ + MTL + texture PNG, usando lo
// stesso percorso (Apple ModelI/O) con cui fu generato `model_nobbox.obj`.
// Cosi' i nomi texture (Texture_diffuseColor.png, _normal, _roughness,
// _occlusion) coincidono con quelli attesi dall'editor dei piani.
//
// Gira anche su Mac Intel (ModelI/O e' disponibile).
//
// Compilazione:
//     swiftc -O usdz2obj.swift -o usdz2obj
// Uso:
//     ./usdz2obj <input.usdz> <output.obj>
// Esempio:
//     ./usdz2obj model_raw.usdz model_raw.obj
//
// L'OBJ, l'MTL e i PNG delle texture vengono scritti nella cartella di output.

import Foundation
import ModelIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Uso: \(args[0]) <input.usdz> <output.obj>")
    exit(2)
}

let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

guard FileManager.default.fileExists(atPath: input.path) else {
    print("[ERROR] input non trovato: \(input.path)")
    exit(1)
}

print("Carico \(input.lastPathComponent) ...")
let asset = MDLAsset(url: input)
print("  oggetti: \(asset.count)")

guard MDLAsset.canExportFileExtension("obj") else {
    print("[ERROR] ModelI/O non sa esportare .obj su questo sistema")
    exit(1)
}

do {
    try asset.export(to: output)
    print("[OK] scritto \(output.path)")
    // elenca i file prodotti nella cartella
    let dir = output.deletingLastPathComponent()
    if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
        let stem = output.deletingPathExtension().lastPathComponent
        let produced = items.filter { $0.hasPrefix(stem) || $0.hasPrefix("Texture") }
        print("  file correlati: \(produced.sorted().joined(separator: ", "))")
    }
} catch {
    print("[FATAL] export fallito: \(error)")
    exit(1)
}

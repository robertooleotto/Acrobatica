import SceneKit
import simd
import UIKit

/// Tipo di faccia proxy (spec §5): determina il ruolo nel bake/preventivo.
enum TipoFaccia: String, CaseIterable, Identifiable {
    case facciata, spalletta, davanzale, orizzontale, torretta, bordo, scarto
    var id: String { rawValue }
    var etichetta: String { rawValue.capitalized }
}

/// Stato del documento proxy (spec §9).
enum StatoProxy: String, CaseIterable, Identifiable {
    case automatico, corretto, bakeReady
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .automatico: return "Automatico"
        case .corretto:   return "Corretto"
        case .bakeReady:  return "Bake-ready"
        }
    }
    var raw: String {
        switch self {
        case .automatico: return "automatico"
        case .corretto:   return "corretto_manualmente"
        case .bakeReady:  return "bake_ready"
        }
    }
}

/// Vista di validazione (spec §8).
enum VistaValidazione: String, CaseIterable, Identifiable {
    case normale, soloAccettate, soloScarti, soloProxy
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .normale:       return "Tutto"
        case .soloAccettate: return "Solo accettate"
        case .soloScarti:    return "Solo scarti"
        case .soloProxy:     return "Solo proxy"
        }
    }
}

/// Faccia proxy (§3): gruppo di triangoli "pennellati" con un colore = un piano.
/// Dopo "Genera piani" porta normale+punto del piano fittato.
struct FacciaProxy: Identifiable {
    let id: Int
    var nome: String
    var colore: UIColor
    var tipo: TipoFaccia = .facciata
    var priorita: Int = 0
    var triangoli: Set<Int> = []
    var pianoPunto: SIMD3<Float>? = nil
    var pianoNormale: SIMD3<Float>? = nil
    var erroreRms: Float? = nil   // planarità: RMS distanza triangoli↔piano

    /// #RRGGBB del colore (per l'export JSON).
    var coloreHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colore.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Palette di colori distinti per le facce (1 colore = 1 faccia).
    static let palette: [UIColor] = [
        UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1),   // rosso
        UIColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1),   // blu
        UIColor(red: 0.18, green: 0.70, blue: 0.44, alpha: 1),   // verde
        UIColor(red: 0.95, green: 0.61, blue: 0.07, alpha: 1),   // arancio
        UIColor(red: 0.61, green: 0.35, blue: 0.71, alpha: 1),   // viola
        UIColor(red: 0.10, green: 0.74, blue: 0.74, alpha: 1),   // teal
        UIColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1),   // giallo
        UIColor(red: 0.91, green: 0.46, blue: 0.64, alpha: 1),   // rosa
    ]
}

/// Mesh editabile on-device: buffer di vertici + triangoli su cui fare
/// selezione e taglio distruttivo (T1 dell'editor 3D). Indipendente da
/// SceneKit per la logica; produce `SCNGeometry` per il rendering.
///
/// Le coordinate sono nello spazio di `contentNode` (identità sotto la radice),
/// quindi coincidono col world space per proiezione/hit-test.
struct EditableMesh: @unchecked Sendable {
    var vertices: [SIMD3<Float>]
    var triangles: [SIMD3<UInt32>]   // ogni elemento = 3 indici nel buffer vertici

    var triangleCount: Int { triangles.count }
    var vertexCount: Int { vertices.count }

    func centroid(_ t: SIMD3<UInt32>) -> SIMD3<Float> {
        (vertices[Int(t.x)] + vertices[Int(t.y)] + vertices[Int(t.z)]) / 3
    }

    /// Normale unitaria del triangolo `i` (per il pennello vincolato).
    func normale(_ i: Int) -> SIMD3<Float> {
        guard triangles.indices.contains(i) else { return SIMD3<Float>(0, 0, 1) }
        let t = triangles[i]
        let n = simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                           vertices[Int(t.z)] - vertices[Int(t.x)])
        let l = simd_length(n)
        return l > 1e-9 ? n / l : SIMD3<Float>(0, 0, 1)
    }

    // MARK: Estrazione da SceneKit

    /// Estrae un'unica mesh editabile da un nodo (con figli), in world space.
    /// Ritorna nil se nessuna geometria triangolare leggibile è presente.
    static func from(node: SCNNode) -> EditableMesh? {
        var verts: [SIMD3<Float>] = []
        var tris: [SIMD3<UInt32>] = []

        func visita(_ n: SCNNode) {
            if let g = n.geometry {
                let m = simd_float4x4(n.worldTransform)
                if let pos = leggiPosizioni(g) {
                    let base = UInt32(verts.count)
                    verts.append(contentsOf: pos.map { p in
                        let w = m * SIMD4<Float>(p, 1)
                        return SIMD3(w.x, w.y, w.z)
                    })
                    for e in g.elements where e.primitiveType == .triangles {
                        if let idx = leggiIndici(e) {
                            var k = 0
                            while k + 2 < idx.count {
                                tris.append(SIMD3(base + idx[k], base + idx[k + 1], base + idx[k + 2]))
                                k += 3
                            }
                        }
                    }
                }
            }
            n.childNodes.forEach(visita)
        }
        visita(node)
        guard !tris.isEmpty else { return nil }
        return EditableMesh(vertices: verts, triangles: tris)
    }

    private static func leggiPosizioni(_ g: SCNGeometry) -> [SIMD3<Float>]? {
        guard let src = g.sources(for: .vertex).first,
              src.usesFloatComponents, src.bytesPerComponent == 4,
              src.componentsPerVector >= 3 else { return nil }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(src.vectorCount)
        src.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<src.vectorCount {
                let off = src.dataOffset + i * src.dataStride
                let x = raw.load(fromByteOffset: off, as: Float.self)
                let y = raw.load(fromByteOffset: off + 4, as: Float.self)
                let z = raw.load(fromByteOffset: off + 8, as: Float.self)
                out.append(SIMD3(x, y, z))
            }
        }
        return out
    }

    private static func leggiIndici(_ e: SCNGeometryElement) -> [UInt32]? {
        let n = e.primitiveCount * 3
        guard n > 0 else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(n)
        e.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            switch e.bytesPerIndex {
            case 2:
                for k in 0..<n { out.append(UInt32(raw.load(fromByteOffset: k * 2, as: UInt16.self))) }
            case 4:
                for k in 0..<n { out.append(raw.load(fromByteOffset: k * 4, as: UInt32.self)) }
            default:
                break
            }
        }
        return out.count == n ? out : nil
    }

    // MARK: Adiacenza / componenti connesse

    /// Per ogni vertice, l'elenco dei triangoli che lo usano.
    private func vertToTris() -> [[Int]] {
        var map = [[Int]](repeating: [], count: vertices.count)
        for (i, t) in triangles.enumerated() {
            map[Int(t.x)].append(i); map[Int(t.y)].append(i); map[Int(t.z)].append(i)
        }
        return map
    }

    /// Id di componente connessa per ogni triangolo (union-find su vertici condivisi).
    func connectedComponents() -> [Int] {
        var parent = Array(0..<vertices.count)
        func find(_ a: Int) -> Int {
            var x = a
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb }
        }
        for t in triangles {
            union(Int(t.x), Int(t.y)); union(Int(t.y), Int(t.z))
        }
        var label = [Int: Int](); var next = 0
        var comp = [Int](repeating: 0, count: triangles.count)
        for (i, t) in triangles.enumerated() {
            let r = find(Int(t.x))
            if let l = label[r] { comp[i] = l }
            else { label[r] = next; comp[i] = next; next += 1 }
        }
        return comp
    }

    /// Triangoli appartenenti a componenti "piccole": le isole staccate dalla
    /// componente principale (frammenti sparsi da ripulire). `frazione` =
    /// soglia rispetto alla componente più grande.
    func frammenti(frazione: Double = 0.05) -> Set<Int> {
        let comp = connectedComponents()
        guard !comp.isEmpty else { return [] }
        var size = [Int: Int]()
        for c in comp { size[c, default: 0] += 1 }
        let maxSize = size.values.max() ?? 0
        let soglia = Int(Double(maxSize) * frazione)
        var sel = Set<Int>()
        for (i, c) in comp.enumerated() where (size[c] ?? 0) <= soglia { sel.insert(i) }
        return sel
    }

    /// Triangoli della componente connessa che contiene `seed` (isola/edificio).
    func isola(contenente seed: Int) -> Set<Int> {
        let comp = connectedComponents()
        guard comp.indices.contains(seed) else { return [] }
        let target = comp[seed]
        var sel = Set<Int>()
        for (i, c) in comp.enumerated() where c == target { sel.insert(i) }
        return sel
    }

    // MARK: Espandi / restringi selezione (anello per vertice condiviso)

    func espandi(_ sel: Set<Int>) -> Set<Int> {
        let v2t = vertToTris()
        var out = sel
        for i in sel {
            let t = triangles[i]
            for v in [Int(t.x), Int(t.y), Int(t.z)] { out.formUnion(v2t[v]) }
        }
        return out
    }

    func restringi(_ sel: Set<Int>) -> Set<Int> {
        let v2t = vertToTris()
        // Togli i triangoli di bordo: quelli con un vertice toccato da un
        // triangolo non selezionato.
        var out = sel
        for i in sel {
            let t = triangles[i]
            for v in [Int(t.x), Int(t.y), Int(t.z)] {
                if v2t[v].contains(where: { !sel.contains($0) }) { out.remove(i); break }
            }
        }
        return out
    }

    // MARK: Box di lavoro (crop)

    /// Bounding box assi-allineato della mesh (lo, hi).
    var aabb: (SIMD3<Float>, SIMD3<Float>) {
        guard let f = vertices.first else { return (.zero, .zero) }
        var lo = f, hi = f
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }

    /// Box ORIENTATO: `origin` + assi `rot` (colonne ortonormali). Un punto è
    /// dentro se le sue coordinate locali `rotᵀ·(p−origin)` stanno in [lo,hi].
    private func dentroOBB(_ c: SIMD3<Float>, _ origin: SIMD3<Float>,
                           _ rot: simd_float3x3, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        let l = rot.transpose * (c - origin)
        return l.x >= lo.x && l.x <= hi.x && l.y >= lo.y && l.y <= hi.y && l.z >= lo.z && l.z <= hi.z
    }

    /// Triangoli col baricentro FUORI dal box orientato (crop = eliminarli).
    func triangoliFuori(_ origin: SIMD3<Float>, _ rot: simd_float3x3,
                        _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Set<Int> {
        var s = Set<Int>()
        for i in triangles.indices where !dentroOBB(centroid(triangles[i]), origin, rot, lo, hi) { s.insert(i) }
        return s
    }

    /// Triangoli col baricentro DENTRO il box orientato (crop invertito).
    func triangoliDentro(_ origin: SIMD3<Float>, _ rot: simd_float3x3,
                         _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Set<Int> {
        var s = Set<Int>()
        for i in triangles.indices where dentroOBB(centroid(triangles[i]), origin, rot, lo, hi) { s.insert(i) }
        return s
    }

    /// Box orientato allineato alla geometria (PCA dei vertici), SENZA ruotare
    /// la mesh: ritorna origine (centroide), assi `rot` (colonne = direzioni
    /// principali, x=spread maggiore, z=normale/spessore), e bounds locali
    /// stretti sui vertici.
    func orientedBox() -> (origin: SIMD3<Float>, rot: simd_float3x3, lo: SIMD3<Float>, hi: SIMD3<Float>) {
        guard vertices.count >= 3 else {
            let (lo, hi) = aabb
            return (.zero, matrix_identity_float3x3, lo, hi)
        }
        // Centroide + matrice di covarianza.
        var mean = SIMD3<Double>(repeating: 0)
        for v in vertices { mean += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) }
        mean /= Double(vertices.count)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for v in vertices {
            let d = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) - mean
            cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
            cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z; cov[2][2] += d.z * d.z
        }
        cov[1][0] = cov[0][1]; cov[2][0] = cov[0][2]; cov[2][1] = cov[1][2]

        let (_, vecs) = Self.eigenSym3(cov)   // colonne ordinate per autovalore decrescente
        var rot = simd_float3x3(
            SIMD3(Float(vecs[0][0]), Float(vecs[1][0]), Float(vecs[2][0])),
            SIMD3(Float(vecs[0][1]), Float(vecs[1][1]), Float(vecs[2][1])),
            SIMD3(Float(vecs[0][2]), Float(vecs[1][2]), Float(vecs[2][2])))
        if simd_determinant(rot) < 0 { rot.columns.2 = -rot.columns.2 }   // destrorso

        let origin = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
        let rt = rot.transpose
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices {
            let l = rt * (v - origin)
            lo = simd_min(lo, l); hi = simd_max(hi, l)
        }
        return (origin, rot, lo, hi)
    }

    /// Frame PCA (3 assi ortonormali, colonne per varianza decrescente) di una
    /// nuvola di punti. col0 = spread maggiore, col2 = minore (≈ normale).
    static func pcaFrame(_ pts: [SIMD3<Float>], origin: SIMD3<Float>) -> simd_float3x3 {
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pts {
            let d = SIMD3<Double>(Double(p.x - origin.x), Double(p.y - origin.y), Double(p.z - origin.z))
            cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
            cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z; cov[2][2] += d.z * d.z
        }
        cov[1][0] = cov[0][1]; cov[2][0] = cov[0][2]; cov[2][1] = cov[1][2]
        let (_, v) = eigenSym3(cov)
        var rot = simd_float3x3(
            SIMD3(Float(v[0][0]), Float(v[1][0]), Float(v[2][0])),
            SIMD3(Float(v[0][1]), Float(v[1][1]), Float(v[2][1])),
            SIMD3(Float(v[0][2]), Float(v[1][2]), Float(v[2][2])))
        if simd_determinant(rot) < 0 { rot.columns.2 = -rot.columns.2 }
        return rot
    }

    /// Box orientato robusto: RANSAC del PIANO DOMINANTE (la facciata) → assi
    /// dalla PCA dei soli inlier (esclude bordi/terreno) → bounds su tutti i
    /// vertici. Più affidabile della PCA grezza su mesh OC frastagliate.
    func orientedBoxRANSAC(iters: Int = 300) -> (origin: SIMD3<Float>, rot: simd_float3x3, lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard vertices.count >= 100 else { return nil }
        let step = max(1, vertices.count / 6000)
        var sample: [SIMD3<Float>] = []
        var i = 0
        while i < vertices.count { sample.append(vertices[i]); i += step }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let thresh = max(ext * 0.01, 1e-4)

        var bestN = SIMD3<Float>(0, 0, 1), bestP = sample[0], bestCount = -1
        for _ in 0..<iters {
            let a = sample.randomElement()!, b = sample.randomElement()!, c = sample.randomElement()!
            let n0 = simd_cross(b - a, c - a)
            let len = simd_length(n0); if len < 1e-6 { continue }
            let n = n0 / len
            var count = 0
            for v in sample where abs(simd_dot(v - a, n)) < thresh { count += 1 }
            if count > bestCount { bestCount = count; bestN = n; bestP = a }
        }
        let inliers = sample.filter { abs(simd_dot($0 - bestP, bestN)) < thresh }
        guard inliers.count >= 20 else { return nil }

        var mean = SIMD3<Float>(repeating: 0)
        for p in inliers { mean += p }
        mean /= Float(inliers.count)

        // Normale precisa dagli inlier (PCA → asse di minima varianza)...
        let pca = Self.pcaFrame(inliers, origin: mean)
        let n = pca.columns.2
        // ...ma verticale/orizzontale ANCORATE al "su" del mondo (la mesh OC sta
        // dritta), così i bordi del box restano verticali/orizzontali e i tagli
        // vengono dritti, non lungo la diagonale della varianza.
        let worldUp = SIMD3<Float>(0, 1, 0)
        var up = worldUp - simd_dot(worldUp, n) * n
        if simd_length(up) < 1e-3 { up = SIMD3<Float>(1, 0, 0) - simd_dot(SIMD3<Float>(1, 0, 0), n) * n }
        up = simd_normalize(up)
        let right = simd_normalize(simd_cross(up, n))
        up = simd_cross(n, right)
        var rot = simd_float3x3(right, up, n)
        if simd_determinant(rot) < 0 { rot.columns.0 = -rot.columns.0 }

        let rt = rot.transpose
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices { let l = rt * (v - mean); lo = simd_min(lo, l); hi = simd_max(hi, l) }
        return (mean, rot, lo, hi)
    }

    /// Autovalori/autovettori di una matrice 3×3 simmetrica (Jacobi ciclico).
    /// Ritorna autovettori come colonne, ordinati per autovalore decrescente.
    static func eigenSym3(_ m: [[Double]]) -> (vals: [Double], vecs: [[Double]]) {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<60 {
            // Elemento fuori-diagonale di modulo massimo.
            var p = 0, q = 1, mx = abs(a[0][1])
            if abs(a[0][2]) > mx { mx = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > mx { mx = abs(a[1][2]); p = 1; q = 2 }
            if mx < 1e-12 { break }
            let phi = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
            let c = cos(phi), s = sin(phi)
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        let vals = [a[0][0], a[1][1], a[2][2]]
        let order = [0, 1, 2].sorted { vals[$0] > vals[$1] }
        let sortedVals = order.map { vals[$0] }
        let sortedVecs = (0..<3).map { r in order.map { v[r][$0] } }
        return (sortedVals, sortedVecs)
    }

    // MARK: Fit piano (per le facce proxy, §3/§4)

    /// Fitta un piano ai vertici dei triangoli `sel` (PCA: normale = direzione
    /// di minima varianza). Ritorna (punto medio, normale unitaria).
    func fitPiano(_ sel: Set<Int>) -> (punto: SIMD3<Float>, normale: SIMD3<Float>)? {
        guard !sel.isEmpty else { return nil }
        var mean = SIMD3<Double>(repeating: 0)
        var n = 0
        for i in sel {
            let t = triangles[i]
            for v in [vertices[Int(t.x)], vertices[Int(t.y)], vertices[Int(t.z)]] {
                mean += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)); n += 1
            }
        }
        guard n >= 3 else { return nil }
        mean /= Double(n)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in sel {
            let t = triangles[i]
            for v in [vertices[Int(t.x)], vertices[Int(t.y)], vertices[Int(t.z)]] {
                let d = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) - mean
                cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
                cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z; cov[2][2] += d.z * d.z
            }
        }
        cov[1][0] = cov[0][1]; cov[2][0] = cov[0][2]; cov[2][1] = cov[1][2]
        let (_, vecs) = Self.eigenSym3(cov)   // colonne ordinate per autovalore decrescente
        // Normale = autovettore col valore minore (colonna 2).
        let nrm = simd_normalize(SIMD3<Float>(Float(vecs[0][2]), Float(vecs[1][2]), Float(vecs[2][2])))
        return (SIMD3(Float(mean.x), Float(mean.y), Float(mean.z)), nrm)
    }

    /// RMS della distanza dei vertici dei triangoli `sel` dal piano (punto,normale).
    func rmsDalPiano(_ sel: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>) -> Float {
        var s = 0.0; var n = 0
        for i in sel {
            let t = triangles[i]
            for v in [vertices[Int(t.x)], vertices[Int(t.y)], vertices[Int(t.z)]] {
                let d = Double(simd_dot(v - punto, normale)); s += d * d; n += 1
            }
        }
        return n > 0 ? Float((s / Double(n)).squareRoot()) : 0
    }

    /// Fit ROBUSTO del piano su un insieme di triangoli (RANSAC, come il
    /// backend `facade_planes`): trova il piano dominante ignorando gli outlier
    /// (finestre/balconi presi per sbaglio nel segno), poi raffina con PCA sugli
    /// inlier. Molto più stabile di `fitPiano` (PCA pura) su pennellate piccole.
    func fitPianoRANSAC(_ sel: Set<Int>,
                        iters: Int = 150,
                        tolDistFraz: Float = 0.005,
                        tolGradi: Float = 15) -> (punto: SIMD3<Float>, normale: SIMD3<Float>)? {
        let arr = Array(sel)
        guard arr.count >= 6 else { return fitPiano(sel) }
        let cent = arr.map { centroid(triangles[$0]) }
        let norm = arr.map { normale($0) }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tol = max(ext * tolDistFraz, 1e-4)
        let cosT = cos(tolGradi * .pi / 180)

        var bestCount = 0
        var bestP = cent[0], bestN = norm[0]
        for _ in 0..<iters {
            let k = Int.random(in: 0..<arr.count)
            let pp = cent[k], pn = norm[k]
            var count = 0
            for j in arr.indices where abs(simd_dot(cent[j] - pp, pn)) < tol
                && abs(simd_dot(norm[j], pn)) > cosT { count += 1 }
            if count > bestCount { bestCount = count; bestP = pp; bestN = pn }
        }
        var inl = Set<Int>()
        for j in arr.indices where abs(simd_dot(cent[j] - bestP, bestN)) < tol
            && abs(simd_dot(norm[j], bestN)) > cosT { inl.insert(arr[j]) }
        return fitPiano(inl) ?? (bestP, bestN)
    }

    // MARK: Crescita planare dal pennello (§3)

    /// Cresce la regione planare dal segno `seed` per APPARTENENZA AL PIANO
    /// (non per topologia: la mesh OC ha vertici splittati e il flood-fill non
    /// si propaga). Dal piano (punto+normale) del seme prende tutti i triangoli
    /// coplanari (entro `tolDistFraz` del lato) e allineati (entro `tolGradi`).
    /// Finestre rientranti e balconi sporgenti hanno offset diverso → esclusi.
    func crescePianare(da seed: Set<Int>, normale pianoN: SIMD3<Float>, punto: SIMD3<Float>,
                       tolGradi: Float = 18, tolDistFraz: Float = 0.008) -> Set<Int> {
        guard !seed.isEmpty else { return seed }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tolDist = max(ext * tolDistFraz, 1e-4)
        let cosT = cos(tolGradi * .pi / 180)
        var result = seed
        for i in triangles.indices where !result.contains(i) {
            if abs(simd_dot(centroid(triangles[i]) - punto, pianoN)) < tolDist,
               abs(simd_dot(normale(i), pianoN)) > cosT {
                result.insert(i)
            }
        }
        return result
    }

    // MARK: Segmentazione automatica in piani (§3)

    /// Segmenta TUTTA la mesh in piani (RANSAC sequenziale per prossimità +
    /// normale). Ritorna, per ogni piano, i triangoli + (punto, normale).
    /// Pesante (CPU): da chiamare off-main con indicatore di avanzamento.
    func segmentaPiani(maxPiani: Int = 10,
                       sogliaDistFrazione: Float = 0.012,
                       sogliaNormaleGradi: Float = 22,
                       minTriangoliFrazione: Float = 0.01,
                       campioni: Int = 60) -> [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] {
        guard triangles.count > 50 else { return [] }
        // Precompute baricentri e normali (una volta sola).
        let cent = triangles.indices.map { centroid(triangles[$0]) }
        let norm = triangles.indices.map { normale($0) }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let thr = max(ext * sogliaDistFrazione, 1e-4)
        let cosN = cos(sogliaNormaleGradi * .pi / 180)
        let minTri = max(Int(Float(triangles.count) * minTriangoliFrazione), 80)

        var pool = Set(triangles.indices)
        var out: [(Set<Int>, SIMD3<Float>, SIMD3<Float>)] = []
        while out.count < maxPiani && pool.count >= minTri {
            let poolArr = Array(pool)
            // Sottocampione per il VOTO (il conteggio sul pool pieno è troppo
            // costoso in debug); gli inlier veri si materializzano dopo.
            let votStep = max(1, poolArr.count / 5000)
            var votanti: [Int] = []
            var k = 0
            while k < poolArr.count { votanti.append(poolArr[k]); k += votStep }
            let fattore = Float(poolArr.count) / Float(votanti.count)

            var bestCount = 0
            var bestP = SIMD3<Float>(0, 0, 0), bestN = SIMD3<Float>(0, 0, 1)
            for _ in 0..<campioni {
                guard let seed = votanti.randomElement() else { break }
                let pp = cent[seed], pn = norm[seed]
                var count = 0
                for ti in votanti where abs(simd_dot(cent[ti] - pp, pn)) < thr
                    && abs(simd_dot(norm[ti], pn)) > cosN { count += 1 }
                if count > bestCount { bestCount = count; bestP = pp; bestN = pn }
            }
            // Stima inlier reali ≈ voti × fattore.
            if Int(Float(bestCount) * fattore) < minTri { break }
            var bestInliers = Set<Int>()
            for ti in poolArr where abs(simd_dot(cent[ti] - bestP, bestN)) < thr
                && abs(simd_dot(norm[ti], bestN)) > cosN { bestInliers.insert(ti) }
            if bestInliers.count < minTri { break }
            let (p, n) = fitPiano(bestInliers) ?? (bestP, bestN)
            out.append((bestInliers, p, n))
            pool.subtract(bestInliers)
        }
        return out
    }

    // MARK: Taglio distruttivo

    /// Rimuove i triangoli selezionati e compatta i vertici orfani.
    /// Ritorna la rimappatura vecchio→nuovo indice di triangolo (-1 = rimosso),
    /// così chi tiene insiemi di indici (facce proxy) può aggiornarsi.
    @discardableResult
    mutating func elimina(_ sel: Set<Int>) -> [Int] {
        var triRemap = [Int](repeating: -1, count: triangles.count)
        guard !sel.isEmpty else {
            for i in triangles.indices { triRemap[i] = i }
            return triRemap
        }
        var nuovi: [SIMD3<UInt32>] = []
        nuovi.reserveCapacity(triangles.count - sel.count)
        for (i, t) in triangles.enumerated() where !sel.contains(i) {
            triRemap[i] = nuovi.count
            nuovi.append(t)
        }
        // Rimappa i vertici ancora usati.
        var rimap = [Int](repeating: -1, count: vertices.count)
        var keptVerts: [SIMD3<Float>] = []
        var keptTris: [SIMD3<UInt32>] = []
        keptTris.reserveCapacity(nuovi.count)
        func idx(_ v: UInt32) -> UInt32 {
            let i = Int(v)
            if rimap[i] < 0 { rimap[i] = keptVerts.count; keptVerts.append(vertices[i]) }
            return UInt32(rimap[i])
        }
        for t in nuovi { keptTris.append(SIMD3(idx(t.x), idx(t.y), idx(t.z))) }
        vertices = keptVerts
        triangles = keptTris
        return triRemap
    }

    // MARK: Rendering

    func scnGeometry(colore: UIColor) -> SCNGeometry {
        var flat: [UInt32] = []
        flat.reserveCapacity(triangles.count * 3)
        for t in triangles { flat.append(t.x); flat.append(t.y); flat.append(t.z) }
        return MeshFactory.geometria(da: vertices, indici: flat, colore: colore)
    }

    /// Overlay dei soli triangoli selezionati (evidenziazione).
    func selezioneGeometry(_ sel: Set<Int>, colore: UIColor) -> SCNGeometry? {
        guard !sel.isEmpty else { return nil }
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        verts.reserveCapacity(sel.count * 3)
        idx.reserveCapacity(sel.count * 3)
        for i in sel {
            let t = triangles[i]
            let b = UInt32(verts.count)
            verts.append(vertices[Int(t.x)])
            verts.append(vertices[Int(t.y)])
            verts.append(vertices[Int(t.z)])
            idx.append(b); idx.append(b + 1); idx.append(b + 2)
        }
        let src = SCNGeometrySource(vertices: verts.map { SCNVector3($0.x, $0.y, $0.z) })
        let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false   // mostra la selezione anche attraverso la mesh
        g.materials = [m]
        return g
    }
}

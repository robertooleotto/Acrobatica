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
    /// Nascondi questo piano dalla scena (solo visualizzazione: non lo elimina).
    var nascosto: Bool = false
    /// Poligono editabile sul piano (vertici 3D in ordine, chiuso): l'area di
    /// QUESTO poligono = m² del piano (Fase B dell'editor poligonale).
    var poligono: [SIMD3<Float>]? = nil

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

    static func leggiPosizioni(_ g: SCNGeometry) -> [SIMD3<Float>]? {
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

    static func leggiIndici(_ e: SCNGeometryElement) -> [UInt32]? {
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

    /// Min/max della proiezione dei vertici lungo `dir` (range per lo slice).
    func rangeLungo(_ dir: SIMD3<Float>) -> (Float, Float) {
        let n = simd_normalize(dir)
        var lo = Float.greatestFiniteMagnitude, hi = -lo
        for v in vertices { let d = simd_dot(v, n); lo = min(lo, d); hi = max(hi, d) }
        return (lo, hi)
    }

    /// Sezione: segmenti dell'intersezione mesh ∩ piano {x·n = s0}. Per il
    /// "rileva perimetro" (slice orizzontale → footprint dell'edificio).
    func sezione(quota s0: Float, normale dir: SIMD3<Float>) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let n = simd_normalize(dir)
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        for t in triangles {
            let v0 = vertices[Int(t.x)], v1 = vertices[Int(t.y)], v2 = vertices[Int(t.z)]
            let d0 = simd_dot(v0, n) - s0, d1 = simd_dot(v1, n) - s0, d2 = simd_dot(v2, n) - s0
            var pts: [SIMD3<Float>] = []
            if (d0 < 0) != (d1 < 0) { pts.append(v0 + (v1 - v0) * (d0 / (d0 - d1))) }
            if (d1 < 0) != (d2 < 0) { pts.append(v1 + (v2 - v1) * (d1 / (d1 - d2))) }
            if (d2 < 0) != (d0 < 0) { pts.append(v2 + (v0 - v2) * (d2 / (d2 - d0))) }
            if pts.count == 2 { segs.append((pts[0], pts[1])) }
        }
        return segs
    }

    /// Area totale (somma dei triangoli) di `sel`, nelle unità della mesh.
    /// Per i m² metrici va moltiplicata per il quadrato della scala mesh→metri.
    func areaTriangoli(_ sel: Set<Int>) -> Float {
        var s: Float = 0
        for i in sel {
            let t = triangles[i]
            let cr = simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                                 vertices[Int(t.z)] - vertices[Int(t.x)])
            s += simd_length(cr) * 0.5
        }
        return s
    }

    /// Spezza `sel` in componenti connesse (triangoli che condividono un vertice
    /// SALDATO per posizione → robusto sui vertici splittati OC). Serve a far
    /// crescere più piani da più zone selezionate in una volta.
    func componentiConnesse(_ sel: Set<Int>) -> [Set<Int>] {
        guard !sel.isEmpty else { return [] }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let inv: Float = 1.0 / max(ext * 1e-3, 1e-6)
        func chiave(_ vi: Int) -> SIMD3<Int32> {
            let v = vertices[vi]
            return SIMD3<Int32>(Int32((v.x * inv).rounded()),
                                Int32((v.y * inv).rounded()),
                                Int32((v.z * inv).rounded()))
        }
        var parent = [Int: Int](); for i in sel { parent[i] = i }
        func find(_ a: Int) -> Int { var x = a; while parent[x]! != x { let p = parent[x]!; parent[x] = parent[p]!; x = parent[x]! }; return x }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        var primo = [SIMD3<Int32>: Int]()
        for i in sel {
            let t = triangles[i]
            for vi in [Int(t.x), Int(t.y), Int(t.z)] {
                let k = chiave(vi)
                if let j = primo[k] { union(i, j) } else { primo[k] = i }
            }
        }
        var gruppi = [Int: Set<Int>]()
        for i in sel { gruppi[find(i), default: []].insert(i) }
        return Array(gruppi.values)
    }

    /// True se i due insiemi di triangoli sono spazialmente attaccati (condividono
    /// un vertice saldato per posizione). Serve al merge complanare "solo se connessi"
    /// (#14): riunisce un muro spezzato dalle finestre, ma NON fonde due torrette.
    func adiacenti(_ a: Set<Int>, _ b: Set<Int>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let inv: Float = 1.0 / max(ext * 1e-3, 1e-6)
        func chiave(_ vi: Int) -> SIMD3<Int32> {
            let v = vertices[vi]
            return SIMD3<Int32>(Int32((v.x * inv).rounded()),
                                Int32((v.y * inv).rounded()),
                                Int32((v.z * inv).rounded()))
        }
        var keysA = Set<SIMD3<Int32>>()
        for i in a { let t = triangles[i]; keysA.insert(chiave(Int(t.x))); keysA.insert(chiave(Int(t.y))); keysA.insert(chiave(Int(t.z))) }
        for i in b {
            let t = triangles[i]
            if keysA.contains(chiave(Int(t.x))) || keysA.contains(chiave(Int(t.y))) || keysA.contains(chiave(Int(t.z))) { return true }
        }
        return false
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

    /// Cresce la regione planare dal segno `seed` per ADIACENZA CONNESSA: salda i
    /// vertici per posizione (la mesh OC li splitta agli spigoli, ma le posizioni
    /// coincidono) per ricostruire l'adiacenza fra triangoli, poi fa un flood-fill
    /// (BFS) che si propaga SOLO ai triangoli attaccati e che restano sul piano del
    /// seme (entro `tolDistFraz` del lato) e allineati (entro `tolGradi`).
    /// Differenza chiave dalla vecchia versione "globale": due superfici complanari
    /// ma SEPARATE nello spazio (es. due torrette) NON si fondono — la crescita si
    /// ferma al vuoto fra di esse. Finestre rientranti/balconi sporgenti (offset
    /// diverso) restano comunque esclusi dal vincolo di distanza.
    /// Adiacenza saldata della mesh (vertici per posizione + mappa spigolo→triangoli).
    /// Costosa da costruire (O(triangoli)): la si calcola una volta e la si riusa
    /// per tutte le crescite (cache nel model).
    struct Adiacenza: @unchecked Sendable {
        let weld: [Int32]
        let edge: [Int64: [Int]]
    }

    static func ekey(_ a: Int32, _ b: Int32) -> Int64 {
        (Int64(min(a, b)) << 32) | Int64(UInt32(max(a, b)))
    }

    /// Costruisce l'adiacenza saldata (steps 1-2 della crescita). Da cacheare.
    func costruisciAdiacenza() -> Adiacenza {
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let inv: Float = 1.0 / max(ext * 1e-3, 1e-6)
        var weld = [Int32](repeating: -1, count: vertices.count)
        var dict = [SIMD3<Int32>: Int32](); dict.reserveCapacity(vertices.count)
        for vi in vertices.indices {
            let v = vertices[vi]
            let k = SIMD3<Int32>(Int32((v.x * inv).rounded()),
                                 Int32((v.y * inv).rounded()),
                                 Int32((v.z * inv).rounded()))
            if let id = dict[k] { weld[vi] = id }
            else { let id = Int32(dict.count); dict[k] = id; weld[vi] = id }
        }
        var edgeMap = [Int64: [Int]](); edgeMap.reserveCapacity(triangles.count * 2)
        for ti in triangles.indices {
            let t = triangles[ti]
            let a = weld[Int(t.x)], b = weld[Int(t.y)], c = weld[Int(t.z)]
            edgeMap[Self.ekey(a, b), default: []].append(ti)
            edgeMap[Self.ekey(b, c), default: []].append(ti)
            edgeMap[Self.ekey(c, a), default: []].append(ti)
        }
        return Adiacenza(weld: weld, edge: edgeMap)
    }

    func crescePianare(da seed: Set<Int>, normale pianoNIniz: SIMD3<Float>, punto puntoIniz: SIMD3<Float>,
                       tolGradi: Float = 18, tolDistFraz: Float = 0.008,
                       tolCrestaGradi: Float = 45,
                       adiacenza adj: Adiacenza? = nil) -> Set<Int> {
        guard !seed.isEmpty else { return seed }
        var pianoN = pianoNIniz   // (#5) mutabili: il piano si ri-fitta mentre cresce
        var punto = puntoIniz
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tolDist = max(ext * tolDistFraz, 1e-4)
        let cosT = cos(tolGradi * .pi / 180)
        let cosCresta = cos(tolCrestaGradi * .pi / 180)   // (#4) barriera sullo spigolo vivo

        // adiacenza saldata: riusa quella in cache o costruiscila al volo
        let a = adj ?? costruisciAdiacenza()
        let weld = a.weld, edgeMap = a.edge
        // 3) flood-fill connesso vincolato al piano (con #4 cresta + #5 ri-fit)
        var result = seed
        var coda = Array(seed); var qi = 0
        var prossimoRefit = max(seed.count * 2, 250)   // ri-fitta il piano a soglie crescenti
        while qi < coda.count {
            let f = coda[qi]; qi += 1
            let nf = normale(f)
            let t = triangles[f]
            let a = weld[Int(t.x)], b = weld[Int(t.y)], c = weld[Int(t.z)]
            for ek in [Self.ekey(a, b), Self.ekey(b, c), Self.ekey(c, a)] {
                guard let vicini = edgeMap[ek] else { continue }
                for g in vicini where !result.contains(g) {
                    let ng = normale(g)
                    // #4 spigolo vivo: non attraversare una cresta netta fra triangoli adiacenti
                    if abs(simd_dot(nf, ng)) <= cosCresta { continue }
                    if abs(simd_dot(centroid(triangles[g]) - punto, pianoN)) < tolDist,
                       abs(simd_dot(ng, pianoN)) > cosT {
                        result.insert(g); coda.append(g)
                    }
                }
            }
            // #5 RMS adattivo: ri-fitta il piano sui triangoli accumulati così non
            // "scivola" su una superficie leggermente curva (mantiene il verso).
            if result.count >= prossimoRefit {
                if let (p2, n2) = fitPiano(result) {
                    punto = p2
                    pianoN = simd_dot(n2, pianoN) < 0 ? -n2 : n2
                }
                prossimoRefit = result.count * 2
            }
        }
        return result
    }

    // MARK: Segmentazione automatica in piani (§3)

    /// Segmentazione Manhattan/Atlanta: stima pochi assi dominanti dell'edificio
    /// dalle normali dei triangoli, poi raggruppa superfici coerenti con quegli assi
    /// per offset. È utile su edifici regolari perché ricompone facciate/spallette
    /// anche se il rumore OC rende le normali locali instabili.
    func segmentaPianiManhattanAtlanta(maxPiani: Int = 80,
                                       maxAssi: Int = 6,
                                       sogliaAsseGradi: Float = 20,
                                       sogliaDistFrazione: Float = 0.006,
                                       minAreaFrazione: Float = 0.00010,
                                       minTriangoliFrazione: Float = 0.00010) -> [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] {
        guard triangles.count > 20 else { return [] }

        struct AxisVote {
            var asse: SIMD3<Float>
            var peso: Float
        }
        struct PlaneBucket {
            var triangoli: Set<Int>
            var area: Float
            var offsetAcc: Float
        }

        let cent = triangles.indices.map { centroid(triangles[$0]) }
        let norm = triangles.indices.map { normale($0) }
        let triArea = triangles.indices.map { i -> Float in
            let t = triangles[i]
            return simd_length(simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                                          vertices[Int(t.z)] - vertices[Int(t.x)])) * 0.5
        }
        let areaTotale = triArea.reduce(0, +)
        let minArea = max(areaTotale * minAreaFrazione, 1e-6)
        let minTri = max(Int(Float(triangles.count) * minTriangoliFrazione), 8)
        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tolOffset = max(ext * sogliaDistFrazione, 1e-4)
        let cosAxis = cos(sogliaAsseGradi * .pi / 180)

        func canonica(_ n0: SIMD3<Float>) -> SIMD3<Float> {
            var n = simd_normalize(n0)
            let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
            if ax >= ay && ax >= az {
                if n.x < 0 { n = -n }
            } else if ay >= ax && ay >= az {
                if n.y < 0 { n = -n }
            } else if n.z < 0 {
                n = -n
            }
            return n
        }

        var assi: [AxisVote] = []
        for ti in triangles.indices {
            let a = triArea[ti]
            guard a > 1e-9 else { continue }
            let n = canonica(norm[ti])
            if let best = assi.indices.max(by: { simd_dot(n, assi[$0].asse) < simd_dot(n, assi[$1].asse) }),
               simd_dot(n, assi[best].asse) > cosAxis {
                assi[best].asse = simd_normalize(assi[best].asse * assi[best].peso + n * a)
                assi[best].peso += a
            } else {
                assi.append(AxisVote(asse: n, peso: a))
            }
        }
        assi = assi.sorted { $0.peso > $1.peso }.prefix(maxAssi).map { $0 }
        guard !assi.isEmpty else { return [] }

        var buckets: [String: PlaneBucket] = [:]
        for ti in triangles.indices {
            let n = norm[ti]
            guard let ai = assi.indices.max(by: { abs(simd_dot(n, assi[$0].asse)) < abs(simd_dot(n, assi[$1].asse)) }) else { continue }
            var axis = assi[ai].asse
            if simd_dot(n, axis) < 0 { axis = -axis }
            guard simd_dot(n, axis) > cosAxis else { continue }
            let d = simd_dot(axis, cent[ti])
            let qd = Int((d / tolOffset).rounded())
            let key = "\(ai),\(qd)"
            let area = triArea[ti]
            if var b = buckets[key] {
                b.triangoli.insert(ti)
                b.area += area
                b.offsetAcc += d * area
                buckets[key] = b
            } else {
                buckets[key] = PlaneBucket(triangoli: [ti], area: area, offsetAcc: d * area)
            }
        }

        var out: [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] = []
        for b in buckets.values where b.triangoli.count >= minTri && b.area >= minArea {
            guard var fit = fitPiano(b.triangoli) else { continue }
            let avg = b.triangoli.reduce(SIMD3<Float>(0, 0, 0)) { $0 + norm[$1] }
            if simd_length(avg) > 1e-6, simd_dot(fit.normale, avg) < 0 { fit.normale = -fit.normale }
            out.append((b.triangoli, fit.punto, fit.normale))
        }

        return out.sorted(by: { areaTriangoli($0.triangoli) > areaTriangoli($1.triangoli) })
            .prefix(maxPiani)
            .map { $0 }
    }

    /// Segmentazione globale per clustering piano: raggruppa triangoli con normale
    /// simile e offset piano compatibile. A differenza del region growing può
    /// ricomporre facciate interrotte da buchi, finestre o parti mancanti della
    /// mesh, perché non richiede connettività diretta.
    func segmentaPianiClustering(maxPiani: Int = 64,
                                 sogliaDistFrazione: Float = 0.007,
                                 sogliaNormaleGradi: Float = 14,
                                 minAreaFrazione: Float = 0.0005,
                                 minTriangoliFrazione: Float = 0.0005) -> [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] {
        guard triangles.count > 20 else { return [] }

        struct Cluster {
            var triangoli: Set<Int>
            var normaleAcc: SIMD3<Float>
            var offsetAcc: Float
            var area: Float

            var normale: SIMD3<Float> {
                simd_length(normaleAcc) > 1e-6 ? simd_normalize(normaleAcc) : SIMD3<Float>(0, 0, 1)
            }

            var offset: Float { area > 1e-8 ? offsetAcc / area : 0 }
        }

        let cent = triangles.indices.map { centroid(triangles[$0]) }
        let norm = triangles.indices.map { normale($0) }
        let triArea = triangles.indices.map { i -> Float in
            let t = triangles[i]
            return simd_length(simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                                          vertices[Int(t.z)] - vertices[Int(t.x)])) * 0.5
        }
        let areaTotale = triArea.reduce(0, +)
        let minArea = max(areaTotale * minAreaFrazione, 1e-6)
        let minTri = max(Int(Float(triangles.count) * minTriangoliFrazione), 8)

        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tolOffset = max(ext * sogliaDistFrazione, 1e-4)

        func canonica(_ n0: SIMD3<Float>) -> SIMD3<Float> {
            var n = simd_normalize(n0)
            let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
            if ax >= ay && ax >= az {
                if n.x < 0 { n = -n }
            } else if ay >= ax && ay >= az {
                if n.y < 0 { n = -n }
            } else if n.z < 0 {
                n = -n
            }
            return n
        }

        var clusters: [Cluster] = []
        var bucketToCluster: [String: Int] = [:]
        let normalStep: Float = 0.10

        for ti in triangles.indices {
            let area = max(triArea[ti], 1e-9)
            let n = canonica(norm[ti])
            let d = simd_dot(n, cent[ti])
            let qx = Int((n.x / normalStep).rounded())
            let qy = Int((n.y / normalStep).rounded())
            let qz = Int((n.z / normalStep).rounded())
            let qd = Int((d / tolOffset).rounded())
            let key = "\(qx),\(qy),\(qz),\(qd)"

            if let ci = bucketToCluster[key] {
                let cn = clusters[ci].normale
                let nn = simd_dot(n, cn) < 0 ? -n : n
                clusters[ci].triangoli.insert(ti)
                clusters[ci].normaleAcc += nn * area
                clusters[ci].offsetAcc += simd_dot(nn, cent[ti]) * area
                clusters[ci].area += area
            } else {
                clusters.append(Cluster(triangoli: [ti],
                                        normaleAcc: n * area,
                                        offsetAcc: d * area,
                                        area: area))
                bucketToCluster[key] = clusters.count - 1
            }
        }

        var out: [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] = []
        for c in clusters where c.triangoli.count >= minTri && c.area >= minArea {
            guard var f = fitPiano(c.triangoli) else { continue }
            if simd_dot(f.normale, c.normale) < 0 { f.normale = -f.normale }
            out.append((c.triangoli, f.punto, f.normale))
        }

        return out.sorted(by: { areaTriangoli($0.triangoli) > areaTriangoli($1.triangoli) })
            .prefix(maxPiani)
            .map { $0 }
    }

    /// Segmentazione deterministica per crescita regionale: parte dai triangoli più
    /// grandi non assegnati e fa un flood-fill solo su triangoli connessi, con
    /// normale compatibile e baricentro vicino allo stesso piano. È più adatta ai
    /// proxy architettonici di RANSAC globale perché non fonde superfici separate e
    /// non cerca "tutti" i piani possibili nello spazio.
    func segmentaPianiRegionGrowing(maxPiani: Int = 36,
                                    sogliaDistFrazione: Float = 0.008,
                                    sogliaNormaleGradi: Float = 18,
                                    minAreaFrazione: Float = 0.001,
                                    minTriangoliFrazione: Float = 0.001) -> [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] {
        guard triangles.count > 20 else { return [] }

        let cent = triangles.indices.map { centroid(triangles[$0]) }
        let norm = triangles.indices.map { normale($0) }
        let triArea = triangles.indices.map { i -> Float in
            let t = triangles[i]
            return simd_length(simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                                          vertices[Int(t.z)] - vertices[Int(t.x)])) * 0.5
        }
        let areaTotale = triArea.reduce(0, +)
        let minArea = max(areaTotale * minAreaFrazione, 1e-6)
        let minTri = max(Int(Float(triangles.count) * minTriangoliFrazione), 12)

        let (alo, ahi) = aabb
        let ext = max(ahi.x - alo.x, max(ahi.y - alo.y, ahi.z - alo.z))
        let tolDist = max(ext * sogliaDistFrazione, 1e-4)
        let cosT = cos(sogliaNormaleGradi * .pi / 180)
        let cosCresta = cos(42 * Float.pi / 180)

        let adj = costruisciAdiacenza()
        let weld = adj.weld, edgeMap = adj.edge
        let semi = triangles.indices.sorted { triArea[$0] > triArea[$1] }
        var disponibili = Set(triangles.indices)
        var out: [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] = []

        func cresci(seed: Int) -> Set<Int> {
            var pianoN = norm[seed]
            var punto = cent[seed]
            var result: Set<Int> = [seed]
            var coda = [seed]
            var qi = 0
            var prossimoRefit = 160

            while qi < coda.count {
                let f = coda[qi]; qi += 1
                let nf = norm[f]
                let t = triangles[f]
                let a = weld[Int(t.x)], b = weld[Int(t.y)], c = weld[Int(t.z)]
                for ek in [Self.ekey(a, b), Self.ekey(b, c), Self.ekey(c, a)] {
                    guard let vicini = edgeMap[ek] else { continue }
                    for g in vicini where disponibili.contains(g) && !result.contains(g) {
                        let ng = norm[g]
                        if abs(simd_dot(nf, ng)) <= cosCresta { continue }
                        guard abs(simd_dot(cent[g] - punto, pianoN)) < tolDist,
                              abs(simd_dot(ng, pianoN)) > cosT else { continue }
                        result.insert(g)
                        coda.append(g)
                    }
                }

                if result.count >= prossimoRefit, let (p2, n2) = fitPiano(result) {
                    punto = p2
                    pianoN = simd_dot(n2, pianoN) < 0 ? -n2 : n2
                    prossimoRefit = result.count * 2
                }
            }
            return result
        }

        for seed in semi where out.count < maxPiani && disponibili.count >= minTri {
            guard disponibili.contains(seed) else { continue }
            let regione = cresci(seed: seed)
            let area = regione.reduce(Float(0)) { $0 + triArea[$1] }
            disponibili.subtract(regione)
            guard regione.count >= minTri, area >= minArea else { continue }
            guard var fit = fitPiano(regione) else { continue }
            if simd_dot(fit.normale, norm[seed]) < 0 { fit.normale = -fit.normale }
            out.append((regione, fit.punto, fit.normale))
        }

        return out.sorted(by: { areaTriangoli($0.triangoli) > areaTriangoli($1.triangoli) })
    }

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
            let (p, n) = fitPianoRANSAC(bestInliers,
                                        iters: 100,
                                        tolDistFraz: sogliaDistFrazione * 0.5,
                                        tolGradi: min(sogliaNormaleGradi, 15)) ?? fitPiano(bestInliers) ?? (bestP, bestN)
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

    // MARK: - Segmentazione a ISTOGRAMMI nel sistema di assi dell'edificio (BCS)

    /// Un piano architettonico estratto dagli istogrammi: quad + normale + tipo.
    struct PianoIstogramma {
        var corners: [SIMD3<Float>]
        var normale: SIMD3<Float>
        var punto: SIMD3<Float>
        var tipo: TipoFaccia
        var area: Float
    }

    /// Frame dell'edificio dalla PCA delle POSIZIONI: una facciata è sottile in
    /// profondità → min varianza = normale; media = verticale; max = larghezza.
    /// Robusto a mesh acquisite storte (assi inclinati). Riusa `eigenSym3`
    /// (autovettori-colonna per autovalore DECRESCENTE).
    func assiPCAEdificio() -> (d: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>) {
        guard !vertices.isEmpty else { return (SIMD3(0,0,1), SIMD3(0,1,0), SIMD3(1,0,0)) }
        var c = SIMD3<Double>(0,0,0)
        for v in vertices { c += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) }
        c /= Double(vertices.count)
        var cov = [[0.0,0,0],[0,0,0],[0,0,0]]
        for v in vertices {
            let q = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) - c
            cov[0][0]+=q.x*q.x; cov[0][1]+=q.x*q.y; cov[0][2]+=q.x*q.z
            cov[1][1]+=q.y*q.y; cov[1][2]+=q.y*q.z; cov[2][2]+=q.z*q.z
        }
        cov[1][0]=cov[0][1]; cov[2][0]=cov[0][2]; cov[2][1]=cov[1][2]
        let (_, vec) = Self.eigenSym3(cov)   // colonne per autovalore DECRESCENTE
        func col(_ k: Int) -> SIMD3<Float> {
            simd_normalize(SIMD3(Float(vec[0][k]), Float(vec[1][k]), Float(vec[2][k])))
        }
        var d = col(2)            // min varianza → normale facciata
        var up = col(1)           // media → verticale
        if up.y < 0 { up = -up }
        let right = simd_normalize(simd_cross(up, d))
        d = simd_normalize(simd_cross(right, up))
        return (d, up, right)
    }

    private func areaTri(_ i: Int) -> Float {
        let t = triangles[i]
        return 0.5 * simd_length(simd_cross(vertices[Int(t.y)] - vertices[Int(t.x)],
                                            vertices[Int(t.z)] - vertices[Int(t.x)]))
    }

    /// Cluster contigui di valori (pesati per area) lungo un asse: bin-izza, tieni
    /// i bin sopra soglia, unisci i contigui colmando vuoti ≤ maxGap.
    private func clusterContigui(_ values: [Float], _ weights: [Float], bin: Float, maxGap: Int) -> [(Float, Float)] {
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return [] }
        let nb = max(1, Int(((hi - lo) / bin).rounded(.up)))
        var hist = [Float](repeating: 0, count: nb)
        for (v, w) in zip(values, weights) {
            let b = min(nb - 1, max(0, Int((v - lo) / bin)))
            hist[b] += w
        }
        let floor = max((hist.max() ?? 0) * 0.02, 1e-9)
        var out: [(Float, Float)] = []
        var i = 0
        while i < nb {
            if hist[i] <= floor { i += 1; continue }
            var j = i, end = i, gap = 0
            while j < nb {
                if hist[j] > floor { end = j; gap = 0 } else { gap += 1; if gap > maxGap { break } }
                j += 1
            }
            out.append((lo + Float(i) * bin, lo + Float(end + 1) * bin))
            i = j
        }
        return out
    }

    private func perc(_ a: [Float], _ f: Float) -> Float {
        guard !a.isEmpty else { return 0 }
        let i = min(a.count - 1, max(0, Int((Float(a.count - 1) * f / 100).rounded())))
        return a[i]
    }

    /// Istogramma lungo `axis` (normale dei piani cercati) → split lungo `eH`;
    /// quad finale nel piano (eH, eV).
    private func pianiLungoAsse(axis: SIMD3<Float>, eH: SIMD3<Float>, eV: SIMD3<Float>, tipo: TipoFaccia,
                                nf: [SIMD3<Float>], cf: [SIMD3<Float>], af: [Float],
                                angTolGradi: Float, bin: Float, minArea: Float, percLo: Float, percHi: Float) -> [PianoIstogramma] {
        let cosTol = cos(angTolGradi * .pi / 180)
        var sel: [Int] = []
        for i in triangles.indices where abs(simd_dot(nf[i], axis)) > cosTol { sel.append(i) }
        guard !sel.isEmpty else { return [] }
        let depth = sel.map { simd_dot(cf[$0], axis) }
        let aSel = sel.map { af[$0] }
        let hco = sel.map { simd_dot(cf[$0], eH) }
        var out: [PianoIstogramma] = []
        func quad(_ faceIdx: [Int]) {
            let ar = faceIdx.reduce(Float(0)) { $0 + af[$1] }
            guard ar >= minArea else { return }
            var vids = Set<Int>()
            for fi in faceIdx { let t = triangles[fi]; vids.insert(Int(t.x)); vids.insert(Int(t.y)); vids.insert(Int(t.z)) }
            var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
            for vi in vids { let v = vertices[vi]; xs.append(simd_dot(v, eH)); ys.append(simd_dot(v, eV)); zs.append(simd_dot(v, axis)) }
            xs.sort(); ys.sort()
            let x0 = perc(xs, percLo), x1 = perc(xs, percHi), y0 = perc(ys, percLo), y1 = perc(ys, percHi)
            guard x1 > x0, y1 > y0 else { return }
            let off = zs.reduce(0, +) / Float(zs.count)
            func p3(_ x: Float, _ y: Float) -> SIMD3<Float> { eH * x + eV * y + axis * off }
            out.append(PianoIstogramma(corners: [p3(x0, y0), p3(x1, y0), p3(x1, y1), p3(x0, y1)],
                                       normale: axis, punto: eH * (x0+x1)/2 + eV * (y0+y1)/2 + axis * off,
                                       tipo: tipo, area: ar))
        }
        for (z0, z1) in clusterContigui(depth, aSel, bin: bin, maxGap: 3) {
            let inDepth = sel.indices.filter { depth[$0] >= z0 - bin && depth[$0] <= z1 + bin }
            guard !inDepth.isEmpty else { continue }
            let hsub = inDepth.map { hco[$0] }, asub = inDepth.map { aSel[$0] }
            for (h0, h1) in clusterContigui(hsub, asub, bin: bin, maxGap: 4) {
                let faces = inDepth.filter { hco[$0] >= h0 - bin && hco[$0] <= h1 + bin }.map { sel[$0] }
                quad(faces)
            }
        }
        return out
    }

    /// Estrae i piani con la pipeline a istogrammi (fronte/lato/alto). `assi` se
    /// passati (override manuale) sostituiscono la stima PCA.
    func segmentaPianiIstogrammi(angTolGradi: Float = 25, binFraz: Float = 0.006, minAreaFraz: Float = 0.02,
                                 percLo: Float = 2, percHi: Float = 98,
                                 assi: (d: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>)? = nil) -> [PianoIstogramma] {
        guard triangles.count > 10 else { return [] }
        let (d, up, right) = assi ?? assiPCAEdificio()
        let nf = triangles.indices.map { normale($0) }
        let cf = triangles.indices.map { centroid(triangles[$0]) }
        let af = triangles.indices.map { areaTri($0) }
        let (lo, hi) = aabb
        let ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        let bin = max(ext * binFraz, 1e-4)
        let cosV = cos(angTolGradi * .pi / 180)
        let areaVert = triangles.indices.filter { abs(simd_dot(nf[$0], up)) < sin(angTolGradi * .pi / 180) }
            .reduce(Float(0)) { $0 + af[$1] }
        let minArea = max(areaVert * minAreaFraz, 1e-4)
        _ = cosV
        var out: [PianoIstogramma] = []
        out += pianiLungoAsse(axis: d, eH: right, eV: up, tipo: .facciata, nf: nf, cf: cf, af: af,
                              angTolGradi: angTolGradi, bin: bin, minArea: minArea, percLo: percLo, percHi: percHi)
        out += pianiLungoAsse(axis: right, eH: d, eV: up, tipo: .spalletta, nf: nf, cf: cf, af: af,
                              angTolGradi: 12, bin: bin, minArea: minArea, percLo: 10, percHi: 90)
        out += pianiLungoAsse(axis: up, eH: right, eV: d, tipo: .orizzontale, nf: nf, cf: cf, af: af,
                              angTolGradi: 12, bin: bin, minArea: minArea, percLo: 10, percHi: 90)
        return out
    }

    /// Pipeline BCS deterministica: usa gli assi dell'edificio (right/up/front),
    /// cerca picchi di area lungo Z per facciate/torrette e lungo X per spallette,
    /// poi genera quad puliti con percentili robusti.
    func segmentaPianiBCS(assi: (right: SIMD3<Float>, up: SIMD3<Float>, front: SIMD3<Float>),
                          binMetri: Float = 0.10,
                          angTolGradi: Float = 15,
                          minAreaFacciata: Float = 2.0,
                          minAreaSpalletta: Float = 0.7,
                          maxFacciate: Int = 7,
                          maxSpallette: Int = 10,
                          percLo: Float = 5,
                          percHi: Float = 95) -> [PianoIstogramma] {
        guard triangles.count > 10, !vertices.isEmpty else { return [] }
        let r = simd_normalize(assi.right)
        let u0 = assi.up - simd_dot(assi.up, r) * r
        let u = simd_length(u0) > 1e-4 ? simd_normalize(u0) : SIMD3<Float>(0, 1, 0)
        var f = assi.front - simd_dot(assi.front, r) * r - simd_dot(assi.front, u) * u
        if simd_length(f) < 1e-4 { f = simd_cross(r, u) }
        f = simd_normalize(f)
        let rot = simd_float3x3(r, u, f)
        let rt = rot.transpose
        let (loW, hiW) = aabb
        let origin = (loW + hiW) / 2
        let localVerts = vertices.map { rt * ($0 - origin) }
        let (loL, hiL) = localVerts.reduce((localVerts[0], localVerts[0])) { acc, v in
            (simd_min(acc.0, v), simd_max(acc.1, v))
        }
        let ext = hiL - loL
        let bin = max(min(binMetri, max(max(ext.x, ext.y), ext.z) * 0.04), max(max(max(ext.x, ext.y), ext.z) * 0.004, 0.01))
        let cosTol = cos(angTolGradi * .pi / 180)

        struct TriBCS {
            let index: Int
            let area: Float
            let c: SIMD3<Float>
            let n: SIMD3<Float>
        }
        var dati: [TriBCS] = []
        dati.reserveCapacity(triangles.count)
        for i in triangles.indices {
            let t = triangles[i]
            let a = localVerts[Int(t.x)], b = localVerts[Int(t.y)], c = localVerts[Int(t.z)]
            let cr = simd_cross(b - a, c - a)
            let ar = simd_length(cr) * 0.5
            guard ar > 1e-9 else { continue }
            dati.append(TriBCS(index: i, area: ar, c: (a + b + c) / 3, n: cr / (ar * 2)))
        }
        guard !dati.isEmpty else { return [] }
        let areaVerticale = dati.filter { abs($0.n.y) < 0.45 }.reduce(Float(0)) { $0 + $1.area }
        let minFront = max(minAreaFacciata, areaVerticale * 0.010)
        let minSide = max(minAreaSpalletta, areaVerticale * 0.003)

        func percent(_ values: [Float], _ p: Float) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * p / 100).rounded())))
            return sorted[idx]
        }

        func peakBins(_ tris: [TriBCS], coord: (SIMD3<Float>) -> Float, minArea: Float, maxCount: Int) -> [(center: Float, area: Float)] {
            guard !tris.isEmpty else { return [] }
            let vals = tris.map { coord($0.c) }
            guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return [] }
            let nb = max(1, Int(((hi - lo) / bin).rounded(.up)) + 1)
            var hist = [Float](repeating: 0, count: nb)
            for (tri, v) in zip(tris, vals) {
                let b = min(nb - 1, max(0, Int(((v - lo) / bin).rounded(.down))))
                hist[b] += tri.area
            }
            let localFloor = max(minArea, (hist.max() ?? 0) * 0.08)
            var peaks: [(Int, Float)] = []
            for i in hist.indices where hist[i] >= localFloor {
                let prev = i > 0 ? hist[i - 1] : -Float.greatestFiniteMagnitude
                let next = i + 1 < hist.count ? hist[i + 1] : -Float.greatestFiniteMagnitude
                if hist[i] >= prev && hist[i] >= next {
                    peaks.append((i, hist[i]))
                }
            }
            peaks.sort { $0.1 > $1.1 }
            var selected: [(center: Float, area: Float)] = []
            for (idx, area) in peaks {
                let center = lo + (Float(idx) + 0.5) * bin
                if selected.contains(where: { abs($0.center - center) < bin * 2.0 }) { continue }
                selected.append((center, area))
                if selected.count >= maxCount { break }
            }
            return selected
        }

        func makePlane(tris: [TriBCS], axis: WritableKeyPath<SIMD3<Float>, Float>,
                       a0: WritableKeyPath<SIMD3<Float>, Float>,
                       a1: WritableKeyPath<SIMD3<Float>, Float>,
                       normal: SIMD3<Float>, tipo: TipoFaccia, minArea: Float) -> PianoIstogramma? {
            let ar = tris.reduce(Float(0)) { $0 + $1.area }
            guard ar >= minArea else { return nil }
            var p0: [Float] = [], p1: [Float] = [], fixedVals: [Float] = []
            p0.reserveCapacity(tris.count * 3); p1.reserveCapacity(tris.count * 3); fixedVals.reserveCapacity(tris.count)
            for tri in tris {
                let t = triangles[tri.index]
                for vi in [Int(t.x), Int(t.y), Int(t.z)] {
                    let v = localVerts[vi]
                    p0.append(v[keyPath: a0])
                    p1.append(v[keyPath: a1])
                }
                fixedVals.append(tri.c[keyPath: axis] * tri.area)
            }
            let x0 = percent(p0, percLo), x1 = percent(p0, percHi)
            let y0 = percent(p1, percLo), y1 = percent(p1, percHi)
            guard x1 - x0 > bin * 2, y1 - y0 > bin * 2 else { return nil }
            let precise = fixedVals.reduce(0, +) / max(ar, 1e-6)
            func local(_ p: Float, _ q: Float) -> SIMD3<Float> {
                var v = SIMD3<Float>(repeating: 0)
                v[keyPath: axis] = precise
                v[keyPath: a0] = p
                v[keyPath: a1] = q
                return v
            }
            let lc = [local(x0, y0), local(x1, y0), local(x1, y1), local(x0, y1)]
            let wc = lc.map { origin + rot * $0 }
            let pn = simd_normalize(rot * normal)
            return PianoIstogramma(corners: wc,
                                   normale: pn,
                                   punto: origin + rot * local((x0 + x1) * 0.5, (y0 + y1) * 0.5),
                                   tipo: tipo,
                                   area: ar)
        }

        let frontali = dati.filter { abs($0.n.z) >= cosTol && abs($0.n.y) < 0.55 }
        let laterali = dati.filter { abs($0.n.x) >= cosTol && abs($0.n.y) < 0.60 }
        var out: [PianoIstogramma] = []
        for peak in peakBins(frontali, coord: { $0.z }, minArea: minFront, maxCount: maxFacciate) {
            let inliers = frontali.filter { abs($0.c.z - peak.center) <= bin * 1.35 }
            let sign: Float = (inliers.reduce(Float(0)) { $0 + $1.n.z * $1.area }) >= 0 ? 1 : -1
            if let p = makePlane(tris: inliers, axis: \.z, a0: \.x, a1: \.y,
                                 normal: SIMD3<Float>(0, 0, sign),
                                 tipo: .facciata, minArea: minFront) {
                out.append(p)
            }
        }
        for peak in peakBins(laterali, coord: { $0.x }, minArea: minSide, maxCount: maxSpallette) {
            let inliers = laterali.filter { abs($0.c.x - peak.center) <= bin * 1.25 }
            let sign: Float = (inliers.reduce(Float(0)) { $0 + $1.n.x * $1.area }) >= 0 ? 1 : -1
            if let p = makePlane(tris: inliers, axis: \.x, a0: \.z, a1: \.y,
                                 normal: SIMD3<Float>(sign, 0, 0),
                                 tipo: .spalletta, minArea: minSide) {
                out.append(p)
            }
        }
        return out.sorted { $0.area > $1.area }
    }
}

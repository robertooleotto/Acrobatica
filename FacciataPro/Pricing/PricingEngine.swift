import Foundation

struct PricingInputProdotto: Equatable {
    let nome: String
    let unitaSimbolo: String
    let formatoVendita: Double
    let prezzoUnitario: Double
    let resaMqPerUnita: Double
    let coefficienteAbbondamento: Double
}

struct PricingInputStep: Equatable {
    let prodotto: PricingInputProdotto
    let mani: Int
    let ordine: Int
}

struct PricingInputCiclo: Equatable {
    let nome: String
    let manodoperaEurMq: Double
    let steps: [PricingInputStep]
}

struct PricingInputAccessoria: Equatable {
    let nome: String
    let unitaLabel: String
    let prezzoUnitario: Double
    let quantita: Double
}

struct PricingParams: Equatable {
    var margineGlobalePerc: Double = 0
    var ivaPerc: Double = 22
}

struct PricingVoce: Equatable {
    let tipo: TipoVocePreventivo
    let descrizione: String
    let quantita: Double
    let unita: String
    let prezzoUnitario: Double
    let totale: Double
}

struct PricingResult: Equatable {
    let voci: [PricingVoce]
    let subtotale: Double
    let conMargine: Double
    let iva: Double
    let totale: Double
}

enum PricingEngine {

    static func calcolaSuperficieNetta(
        superficieLorda: Double,
        elementiEsclusi: [Double],
        elementiExtra: [Double]
    ) -> Double {
        let lorda = max(0, superficieLorda)
        let esclusi = elementiEsclusi.reduce(0, +)
        let extra = elementiExtra.reduce(0, +)
        return max(0, lorda - esclusi + extra)
    }

    static func calcola(
        superficieNetta: Double,
        ciclo: PricingInputCiclo,
        vociAccessorie: [PricingInputAccessoria],
        params: PricingParams
    ) -> PricingResult {
        var voci: [PricingVoce] = []

        for step in ciclo.steps.sorted(by: { $0.ordine < $1.ordine }) {
            let p = step.prodotto
            guard p.resaMqPerUnita > 0, p.formatoVendita > 0 else { continue }

            let qtyTeorica = (superficieNetta * Double(step.mani)) / p.resaMqPerUnita
            let qtyAbbondante = qtyTeorica * p.coefficienteAbbondamento
            let nConfezioni = max(0, Int(ceil(qtyAbbondante / p.formatoVendita)))
            let prezzoConf = p.formatoVendita * p.prezzoUnitario
            let totale = Double(nConfezioni) * prezzoConf

            voci.append(PricingVoce(
                tipo: .materiale,
                descrizione: "\(p.nome) (\(step.mani) man\(step.mani == 1 ? "o" : "i"))",
                quantita: Double(nConfezioni),
                unita: "conf. da \(formatNumero(p.formatoVendita))\(p.unitaSimbolo)",
                prezzoUnitario: prezzoConf,
                totale: totale
            ))
        }

        let totaleManodopera = superficieNetta * ciclo.manodoperaEurMq
        voci.append(PricingVoce(
            tipo: .manodopera,
            descrizione: "Manodopera applicazione (\(ciclo.nome))",
            quantita: superficieNetta,
            unita: "m²",
            prezzoUnitario: ciclo.manodoperaEurMq,
            totale: totaleManodopera
        ))

        for v in vociAccessorie {
            voci.append(PricingVoce(
                tipo: .accessoria,
                descrizione: v.nome,
                quantita: v.quantita,
                unita: v.unitaLabel,
                prezzoUnitario: v.prezzoUnitario,
                totale: v.quantita * v.prezzoUnitario
            ))
        }

        let subtotale = voci.reduce(0) { $0 + $1.totale }
        let conMargine = subtotale * (1 + params.margineGlobalePerc / 100)
        let iva = conMargine * (params.ivaPerc / 100)
        let totale = conMargine + iva

        return PricingResult(
            voci: voci,
            subtotale: subtotale,
            conMargine: conMargine,
            iva: iva,
            totale: totale
        )
    }

    private static func formatNumero(_ n: Double) -> String {
        if n.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(n))
        }
        return String(format: "%g", n)
    }
}

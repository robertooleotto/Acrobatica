import Foundation
import SwiftData

enum PreventivoBuilder {

    struct VoceComputata {
        let facciataId: UUID?
        let voce: PricingVoce
        let ordine: Int
    }

    struct ComputedResult {
        let voci: [VoceComputata]
        let subtotale: Double
        let conMargine: Double
        let iva: Double
        let totale: Double
    }

    static func calcola(
        facciate: [Facciata],
        cicliById: [UUID: CicloLavorazione],
        vociAccessorie: [(voce: VoceAccessoria, quantita: Double)],
        params: PricingParams
    ) -> ComputedResult {
        var allVoci: [VoceComputata] = []
        var ordine = 0

        for f in facciate {
            guard let cicloId = f.cicloLavorazioneId,
                  let ciclo = cicliById[cicloId] else { continue }
            let inputCiclo = mapCiclo(ciclo)

            let res = PricingEngine.calcola(
                superficieNetta: f.superficieNettaMq,
                ciclo: inputCiclo,
                vociAccessorie: [],
                params: PricingParams(margineGlobalePerc: 0, ivaPerc: 0)
            )
            for v in res.voci {
                allVoci.append(VoceComputata(facciataId: f.id, voce: v, ordine: ordine))
                ordine += 1
            }
        }

        // Voci accessorie a livello cantiere (facciataId = nil).
        for entry in vociAccessorie {
            let v = entry.voce
            let q = entry.quantita
            let voce = PricingVoce(
                tipo: .accessoria,
                descrizione: v.nome,
                quantita: q,
                unita: v.unita.label,
                prezzoUnitario: v.prezzo,
                totale: q * v.prezzo
            )
            allVoci.append(VoceComputata(facciataId: nil, voce: voce, ordine: ordine))
            ordine += 1
        }

        let subtotale = allVoci.reduce(0) { $0 + $1.voce.totale }
        let conMargine = subtotale * (1 + params.margineGlobalePerc / 100)
        let iva = conMargine * (params.ivaPerc / 100)
        let totale = conMargine + iva

        return ComputedResult(
            voci: allVoci,
            subtotale: subtotale,
            conMargine: conMargine,
            iva: iva,
            totale: totale
        )
    }

    private static func mapCiclo(_ c: CicloLavorazione) -> PricingInputCiclo {
        let steps = c.stepsOrdinati.compactMap { step -> PricingInputStep? in
            guard let p = step.prodotto else { return nil }
            return PricingInputStep(
                prodotto: PricingInputProdotto(
                    nome: p.nomeCommerciale,
                    unitaSimbolo: p.unita.simbolo,
                    formatoVendita: p.formatoVendita,
                    prezzoUnitario: p.prezzoUnitario,
                    resaMqPerUnita: p.resaMqPerUnita,
                    coefficienteAbbondamento: p.coefficienteAbbondamento
                ),
                mani: step.mani,
                ordine: step.ordine
            )
        }
        return PricingInputCiclo(
            nome: c.nome,
            manodoperaEurMq: c.manodoperaEurMq,
            steps: steps
        )
    }

    /// Persiste il preventivo nel context: crea Preventivo + VocePreventivo entries.
    @MainActor
    static func persisti(
        result: ComputedResult,
        cantiere: Cantiere,
        params: PricingParams,
        validitaGiorni: Int,
        condizioniPagamento: String,
        prefissoNumero: String,
        mostraDettaglio: Bool,
        mostraPerFacciata: Bool,
        context: ModelContext
    ) -> Preventivo {
        let numero = generaNumero(prefisso: prefissoNumero)
        let prev = Preventivo(
            numero: numero,
            dataEmissione: Date(),
            validitaGiorni: validitaGiorni,
            condizioniPagamento: condizioniPagamento,
            tempiConsegna: "",
            note: "",
            mostraDettaglioMateriali: mostraDettaglio,
            mostraPrezziPerFacciata: mostraPerFacciata,
            margineGlobalePerc: params.margineGlobalePerc,
            ivaPerc: params.ivaPerc,
            imponibile: result.conMargine,
            ivaEur: result.iva,
            totale: result.totale,
            cantiere: cantiere
        )
        context.insert(prev)

        for vc in result.voci {
            let vp = VocePreventivo(
                tipo: vc.voce.tipo,
                descrizione: vc.voce.descrizione,
                quantita: vc.voce.quantita,
                unitaMisura: vc.voce.unita,
                prezzoUnitario: vc.voce.prezzoUnitario,
                totale: vc.voce.totale,
                ordine: vc.ordine,
                facciataId: vc.facciataId,
                preventivo: prev
            )
            context.insert(vp)
        }

        try? context.save()
        return prev
    }

    private static func generaNumero(prefisso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        return "\(prefisso)-\(f.string(from: Date()))"
    }
}

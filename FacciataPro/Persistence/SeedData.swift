import Foundation
import SwiftData

enum SeedData {
    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let prodottiCount = (try? context.fetchCount(FetchDescriptor<Prodotto>())) ?? 0
        guard prodottiCount == 0 else { return }

        let prodotti = seedProdotti()
        for p in prodotti { context.insert(p) }

        let voci = seedVociAccessorie()
        for v in voci { context.insert(v) }

        let cicli = seedCicli(prodotti: prodotti)
        for c in cicli {
            context.insert(c)
            for s in c.steps { context.insert(s) }
        }

        try? context.save()
    }

    static func seedProdotti() -> [Prodotto] {
        [
            Prodotto(nomeCommerciale: "Fissativo universale", brand: "Generico",
                     categoria: .fissativo, unita: .litro,
                     formatoVendita: 10, prezzoUnitario: 6.0,
                     resaMqPerUnita: 8, coefficienteAbbondamento: 1.15, maniConsigliate: 1),
            Prodotto(nomeCommerciale: "Idropittura standard", brand: "Generico",
                     categoria: .idropittura, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 4.5,
                     resaMqPerUnita: 6, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Idropittura premium", brand: "Generico",
                     categoria: .idropittura, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 8.0,
                     resaMqPerUnita: 7, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Silossanico esterno", brand: "Generico",
                     categoria: .silossanico, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 12.0,
                     resaMqPerUnita: 7, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Silossanico premium", brand: "Generico",
                     categoria: .silossanico, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 18.0,
                     resaMqPerUnita: 7, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Pittura ai silicati", brand: "Generico",
                     categoria: .silicati, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 22.0,
                     resaMqPerUnita: 7, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Rasante per facciata", brand: "Generico",
                     categoria: .intonaco_rasante, unita: .sacco,
                     formatoVendita: 25, prezzoUnitario: 18.0,
                     resaMqPerUnita: 5, coefficienteAbbondamento: 1.15, maniConsigliate: 1),
            Prodotto(nomeCommerciale: "Pittura termica", brand: "Generico",
                     categoria: .termico, unita: .litro,
                     formatoVendita: 12, prezzoUnitario: 35.0,
                     resaMqPerUnita: 6, coefficienteAbbondamento: 1.15, maniConsigliate: 2),
            Prodotto(nomeCommerciale: "Decorativo effetto sabbia", brand: "Generico",
                     categoria: .decorativo, unita: .litro,
                     formatoVendita: 14, prezzoUnitario: 28.0,
                     resaMqPerUnita: 5, coefficienteAbbondamento: 1.15, maniConsigliate: 1),
            Prodotto(nomeCommerciale: "Primer minerale", brand: "Generico",
                     categoria: .fissativo, unita: .litro,
                     formatoVendita: 10, prezzoUnitario: 14.0,
                     resaMqPerUnita: 8, coefficienteAbbondamento: 1.15, maniConsigliate: 1)
        ]
    }

    static func seedVociAccessorie() -> [VoceAccessoria] {
        [
            VoceAccessoria(nome: "Ponteggio", unita: .a_corpo, prezzo: 800),
            VoceAccessoria(nome: "Protezioni serramenti", unita: .a_corpo, prezzo: 150),
            VoceAccessoria(nome: "Smaltimento rifiuti edili", unita: .a_corpo, prezzo: 200),
            VoceAccessoria(nome: "Trasferta", unita: .a_giornata, prezzo: 80)
        ]
    }

    static func seedCicli(prodotti: [Prodotto]) -> [CicloLavorazione] {
        func find(_ nome: String) -> Prodotto? {
            prodotti.first { $0.nomeCommerciale == nome }
        }

        let economico = CicloLavorazione(
            nome: "Ciclo economico", categoria: .esterno, manodoperaEurMq: 12
        )
        if let fix = find("Fissativo universale") {
            economico.steps.append(StepCiclo(ordine: 1, mani: 1, ciclo: economico, prodotto: fix))
        }
        if let idro = find("Idropittura standard") {
            economico.steps.append(StepCiclo(ordine: 2, mani: 2, ciclo: economico, prodotto: idro))
        }

        let silStd = CicloLavorazione(
            nome: "Ciclo silossanico standard", categoria: .esterno, manodoperaEurMq: 18
        )
        if let fix = find("Fissativo universale") {
            silStd.steps.append(StepCiclo(ordine: 1, mani: 1, ciclo: silStd, prodotto: fix))
        }
        if let sil = find("Silossanico esterno") {
            silStd.steps.append(StepCiclo(ordine: 2, mani: 2, ciclo: silStd, prodotto: sil))
        }

        let silPrem = CicloLavorazione(
            nome: "Ciclo silossanico premium", categoria: .esterno, manodoperaEurMq: 22
        )
        if let prim = find("Primer minerale") {
            silPrem.steps.append(StepCiclo(ordine: 1, mani: 1, ciclo: silPrem, prodotto: prim))
        }
        if let sil = find("Silossanico premium") {
            silPrem.steps.append(StepCiclo(ordine: 2, mani: 2, ciclo: silPrem, prodotto: sil))
        }

        return [economico, silStd, silPrem]
    }
}

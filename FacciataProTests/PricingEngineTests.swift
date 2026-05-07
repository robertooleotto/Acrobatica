import XCTest
@testable import FacciataPro

final class PricingEngineTests: XCTestCase {

    private func fissativo() -> PricingInputProdotto {
        PricingInputProdotto(
            nome: "Fissativo universale",
            unitaSimbolo: "L",
            formatoVendita: 10,
            prezzoUnitario: 6.0,
            resaMqPerUnita: 8,
            coefficienteAbbondamento: 1.15
        )
    }

    private func silossanico() -> PricingInputProdotto {
        PricingInputProdotto(
            nome: "Silossanico esterno",
            unitaSimbolo: "L",
            formatoVendita: 14,
            prezzoUnitario: 12.0,
            resaMqPerUnita: 7,
            coefficienteAbbondamento: 1.15
        )
    }

    func test_superficieNetta_sommaCorrettamente() {
        let netta = PricingEngine.calcolaSuperficieNetta(
            superficieLorda: 100,
            elementiEsclusi: [5, 3, 2],
            elementiExtra: [4]
        )
        XCTAssertEqual(netta, 94, accuracy: 0.0001)
    }

    func test_superficieNetta_nonScendeSottoZero() {
        let netta = PricingEngine.calcolaSuperficieNetta(
            superficieLorda: 10,
            elementiEsclusi: [50],
            elementiExtra: []
        )
        XCTAssertEqual(netta, 0)
    }

    func test_arrotondamento_versoLAlto_alFormatoVendita() {
        // 50 mq, 1 mano, fissativo: resa 8 → 50/8 = 6.25 L teorici
        // *1.15 = 7.1875 L → 1 confezione da 10 L
        let ciclo = PricingInputCiclo(
            nome: "Test", manodoperaEurMq: 0,
            steps: [PricingInputStep(prodotto: fissativo(), mani: 1, ordine: 1)]
        )
        let result = PricingEngine.calcola(
            superficieNetta: 50, ciclo: ciclo,
            vociAccessorie: [],
            params: PricingParams(margineGlobalePerc: 0, ivaPerc: 0)
        )
        let materiali = result.voci.filter { $0.tipo == .materiale }
        XCTAssertEqual(materiali.count, 1)
        XCTAssertEqual(materiali[0].quantita, 1, "1 confezione")
        XCTAssertEqual(materiali[0].totale, 60.0, accuracy: 0.001, "1 conf × 10L × 6€ = 60€")
    }

    func test_arrotondamento_quandoServonoDueLatte() {
        // 100 mq, 2 mani, silossanico: 100*2/7 = 28.57 L
        // *1.15 = 32.86 L → 3 confezioni da 14 L (perché 32.86/14 = 2.347 → ceil 3)
        let ciclo = PricingInputCiclo(
            nome: "Test", manodoperaEurMq: 0,
            steps: [PricingInputStep(prodotto: silossanico(), mani: 2, ordine: 1)]
        )
        let result = PricingEngine.calcola(
            superficieNetta: 100, ciclo: ciclo,
            vociAccessorie: [],
            params: PricingParams(margineGlobalePerc: 0, ivaPerc: 0)
        )
        let materiali = result.voci.filter { $0.tipo == .materiale }
        XCTAssertEqual(materiali[0].quantita, 3)
        XCTAssertEqual(materiali[0].totale, 504, accuracy: 0.01, "3 × 14 × 12 = 504")
    }

    func test_manodopera_perMqNetti() {
        let ciclo = PricingInputCiclo(
            nome: "Test", manodoperaEurMq: 18, steps: []
        )
        let result = PricingEngine.calcola(
            superficieNetta: 81, ciclo: ciclo,
            vociAccessorie: [],
            params: PricingParams(margineGlobalePerc: 0, ivaPerc: 0)
        )
        let manod = result.voci.first { $0.tipo == .manodopera }
        XCTAssertNotNil(manod)
        XCTAssertEqual(manod?.totale, 81 * 18, accuracy: 0.001)
    }

    func test_voceAccessoria_aCorpo_nonScalata() {
        let ciclo = PricingInputCiclo(nome: "x", manodoperaEurMq: 0, steps: [])
        let result = PricingEngine.calcola(
            superficieNetta: 200,
            ciclo: ciclo,
            vociAccessorie: [
                PricingInputAccessoria(nome: "Ponteggio", unitaLabel: "a corpo", prezzoUnitario: 800, quantita: 1)
            ],
            params: PricingParams(margineGlobalePerc: 0, ivaPerc: 0)
        )
        let acc = result.voci.first { $0.tipo == .accessoria }
        XCTAssertEqual(acc?.totale, 800, "Voce a corpo non si moltiplica per la superficie")
    }

    func test_margine_eIvaApplicatiInOrdine() {
        // subtotale 1000, margine 20% → 1200, IVA 10% → 120, totale 1320
        let ciclo = PricingInputCiclo(nome: "x", manodoperaEurMq: 0, steps: [])
        let result = PricingEngine.calcola(
            superficieNetta: 1,
            ciclo: ciclo,
            vociAccessorie: [
                PricingInputAccessoria(nome: "Lump", unitaLabel: "a corpo", prezzoUnitario: 1000, quantita: 1)
            ],
            params: PricingParams(margineGlobalePerc: 20, ivaPerc: 10)
        )
        XCTAssertEqual(result.subtotale, 1000, accuracy: 0.01)
        XCTAssertEqual(result.conMargine, 1200, accuracy: 0.01)
        XCTAssertEqual(result.iva, 120, accuracy: 0.01)
        XCTAssertEqual(result.totale, 1320, accuracy: 0.01)
    }

    func test_resa_zero_nonProduceVoceMateriale() {
        let prod = PricingInputProdotto(
            nome: "Broken", unitaSimbolo: "L", formatoVendita: 10,
            prezzoUnitario: 5, resaMqPerUnita: 0, coefficienteAbbondamento: 1.15
        )
        let ciclo = PricingInputCiclo(
            nome: "x", manodoperaEurMq: 0,
            steps: [PricingInputStep(prodotto: prod, mani: 2, ordine: 1)]
        )
        let result = PricingEngine.calcola(
            superficieNetta: 50, ciclo: ciclo,
            vociAccessorie: [],
            params: PricingParams()
        )
        XCTAssertTrue(result.voci.filter { $0.tipo == .materiale }.isEmpty)
    }
}

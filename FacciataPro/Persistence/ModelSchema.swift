import Foundation
import SwiftData

enum AppSchema {
    static let allModels: [any PersistentModel.Type] = [
        Azienda.self,
        Cliente.self,
        Cantiere.self,
        Facciata.self,
        ElementoEscluso.self,
        ElementoExtra.self,
        SimulazioneTinta.self,
        Prodotto.self,
        CicloLavorazione.self,
        StepCiclo.self,
        VoceAccessoria.self,
        Preventivo.self,
        VocePreventivo.self
    ]

    @MainActor
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema(allModels)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Impossibile creare ModelContainer: \(error)")
        }
    }
}

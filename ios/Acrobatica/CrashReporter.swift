import Foundation
import UIKit
import SwiftUI

/// Cattura crash (eccezioni Obj-C + segnali POSIX) e salva motivo + stack su
/// file, così al riavvio possiamo vedere COME è crashata l'app. Strumento di
/// debug: scrivere su disco in un signal handler non è formalmente
/// async-signal-safe, ma in pratica cattura lo stack a sufficienza.
enum CrashReporter {

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last_crash.txt")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let testo = """
            [ECCEZIONE]  \(CrashReporter.timestamp())
            \(ex.name.rawValue): \(ex.reason ?? "—")

            \(ex.callStackSymbols.joined(separator: "\n"))
            """
            try? testo.write(to: CrashReporter.fileURL, atomically: true, encoding: .utf8)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                let testo = """
                [SEGNALE \(s)]  \(CrashReporter.timestamp())
                \(CrashReporter.nomeSegnale(s))

                \(Thread.callStackSymbols.joined(separator: "\n"))
                """
                try? testo.write(to: CrashReporter.fileURL, atomically: true, encoding: .utf8)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func ultimoCrash() -> String? {
        guard let t = try? String(contentsOf: fileURL, encoding: .utf8), !t.isEmpty else { return nil }
        return t
    }

    static func cancella() { try? FileManager.default.removeItem(at: fileURL) }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func nomeSegnale(_ s: Int32) -> String {
        switch s {
        case SIGABRT: return "SIGABRT (abort / assertion / fatalError)"
        case SIGILL:  return "SIGILL (istruzione illegale)"
        case SIGSEGV: return "SIGSEGV (accesso memoria non valido)"
        case SIGFPE:  return "SIGFPE (errore aritmetico)"
        case SIGBUS:  return "SIGBUS (bus error)"
        case SIGTRAP: return "SIGTRAP (trap / precondition / index out of range)"
        default:      return "segnale \(s)"
        }
    }
}

/// Schermata che, al riavvio dopo un crash, mostra il report con tasto Condividi.
struct CrashBanner: ViewModifier {
    @State private var report: String?
    @State private var condividi = false

    func body(content: Content) -> some View {
        content
            .onAppear { if report == nil { report = CrashReporter.ultimoCrash() } }
            .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { chiudi() } })) {
                if let r = report { reportView(r) }
            }
    }

    private func reportView(_ r: String) -> some View {
        NavigationStack {
            ScrollView {
                Text(r)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Crash precedente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { chiudi() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { condividi = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(isPresented: $condividi) { CondivisioneCrash(testo: r) }
        }
    }

    private func chiudi() {
        report = nil
        CrashReporter.cancella()
    }
}

extension View {
    /// Mostra il report del crash precedente, se presente.
    func crashBanner() -> some View { modifier(CrashBanner()) }
}

private struct CondivisioneCrash: UIViewControllerRepresentable {
    let testo: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [testo], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

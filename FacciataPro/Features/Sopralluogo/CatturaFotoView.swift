import SwiftUI
import PhotosUI
import UIKit

struct CatturaFotoView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var apriCamera = false
    @State private var pickerItem: PhotosPickerItem?

    private var hasFoto: Bool { stato.fotoData != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("3.1 · Cattura foto")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text("Scatta o seleziona una foto della facciata")
                    .font(.title3.bold())

                if let data = stato.fotoData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.tint.opacity(0.10))
                        .frame(height: 280)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.tint)
                                Text("Nessuna foto").foregroundStyle(.secondary)
                            }
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CONSIGLI").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("• Distanza minima 8-10 m dalla facciata")
                    Text("• Mantieni la fotocamera parallela al muro")
                    Text("• Includi un riferimento noto (porta, finestra)")
                    Text("• Buona luce, no controluce")
                }
                .font(.caption)
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            apriCamera = true
                        } label: {
                            Label("Scatta", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Libreria", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("Cattura foto")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $apriCamera) {
            CameraPicker(sourceType: .camera) { jpeg in
                stato.fotoData = jpeg
                resetGeometria()
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        stato.fotoData = data
                        resetGeometria()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasFoto)
            }
        }
    }

    private func resetGeometria() {
        // Nuova foto → reset dei 4 angoli al riquadro di default (~bordi).
        stato.angoloTL = CGPoint(x: 0.05, y: 0.05)
        stato.angoloTR = CGPoint(x: 0.95, y: 0.05)
        stato.angoloBR = CGPoint(x: 0.95, y: 0.95)
        stato.angoloBL = CGPoint(x: 0.05, y: 0.95)
        stato.fotoRaddrizzataData = nil
        stato.fotoRaddrizzataWidthPx = 0
        stato.fotoRaddrizzataHeightPx = 0
        stato.pixelPerCm = 0
        stato.larghezzaM = 0
        stato.altezzaM = 0
    }
}

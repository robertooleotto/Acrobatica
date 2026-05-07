import SwiftUI

struct PlaceholderView: View {
    let screenCode: String
    let title: String
    let phase: String
    let todo: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(screenCode)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.15))
                        .clipShape(Capsule())
                    Text(phase)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 8) {
                    Text("DA IMPLEMENTARE")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(todo, id: \.self) { item in
                        HStack(alignment: .top) {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                            Text(item)
                                .font(.callout)
                        }
                    }
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PlaceholderView(
            screenCode: "3.1",
            title: "Cattura foto",
            phase: "Fase 3",
            todo: ["Fotocamera fullscreen", "Overlay griglia + livello", "CMMotionManager"]
        )
    }
}

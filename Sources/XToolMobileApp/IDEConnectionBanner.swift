import SwiftUI

struct IDEConnectionBanner: View {
    let title: String
    let subtitle: String
    let symbol: String
    let connected: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.cyan)
                .frame(width: 48, height: 48)
                .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .accessibilityLabel(connected ? "Connected" : "Setup available")
        }.padding(20)
    }
}

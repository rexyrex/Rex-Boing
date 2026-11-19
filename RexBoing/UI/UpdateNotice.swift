import SwiftUI

/// "Rex Boing 1.4.0 is available", in a slim band under the dashboard's
/// header and over the Monitor window's cards while a newer release is out,
/// and nothing at all otherwise. One click opens the release page.
///
/// It observes the update check and nothing else, so a notice coming or going
/// redraws this band and not the cards around it.
struct UpdateNotice: View {
    @ObservedObject private var check = UpdateCheck.shared

    var body: some View {
        if let release = check.available {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cpu)
                    .accessibilityHidden(true)
                Text("Rex Boing \(release.version) is available")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("You have \(check.currentVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Download…") { check.openReleasePage() }
                    .controlSize(.small)
                    .help("Open the release page on GitHub")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Palette.cpu.opacity(0.10))
            .accessibilityElement(children: .contain)
        }
    }
}

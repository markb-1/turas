import SwiftUI

/// Shown instead of the map when the build has no server URL or API key,
/// so a misconfigured Release build explains itself instead of crashing.
struct ServerNotConfiguredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Server not configured")
                .font(.title2.weight(.semibold))
            Text("This build of Turas has no server address or API key, so it cannot load live transport data.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    ServerNotConfiguredView()
}

import SwiftUI

/// A one-line notice above the timeline: a note, a warning with an
/// optional action (Retry), or progress.
struct StatusBanner: View {
    enum Kind {
        case info
        case warning
        case progress
    }

    let kind: Kind
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .info:
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.late)
                    .accessibilityHidden(true)
            case .progress:
                ProgressView()
                    .controlSize(.small)
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .accessibilityIdentifier("home.banner.action")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.banner")
    }
}

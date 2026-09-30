import SwiftUI

/// An avatar whose colour is derived deterministically from `text`, so the same
/// name always gets the same colour across launches. Shows the first letter by
/// default, or an SF Symbol when `systemImage` is provided (e.g. a building
/// glyph for companies).
///
/// The shape follows the subject: people are circles, companies are rounded
/// squares. Two silhouettes mean a mixed list can be sorted by glance before any
/// of it is read.
struct MonogramAvatar: View {
    let text: String
    var size: CGFloat = Theme.Avatar.medium
    var systemImage: String? = nil

    private var monogram: String {
        String(text.first ?? "?").uppercased()
    }

    private var accent: Color { .monogram(for: text) }

    /// Companies (the ones drawn with a symbol) get the squarer silhouette.
    private var shape: AnyShape {
        systemImage == nil
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.4, weight: .medium))
            } else {
                Text(monogram)
                    .font(.display(size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(accent, in: shape)
    }
}

extension MonogramAvatar {
    /// A company's avatar: the building glyph on the squarer silhouette.
    init(company name: String, size: CGFloat = Theme.Avatar.medium) {
        self.init(text: name, size: size, systemImage: "building.2.fill")
    }
}

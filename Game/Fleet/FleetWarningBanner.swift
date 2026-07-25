import SwiftUI

struct FleetWarningBanner: View {
    let title: String
    let detail: String
    let tint: Color

    init(title: String = "大破警告", detail: String, tint: Color = .red) {
        self.title = title
        self.detail = detail
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

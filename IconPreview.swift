import SwiftUI

struct IconPreview: View {
    struct IconSize {
        let size: CGFloat
        let label: String
    }

    // List of common icon sizes with descriptive labels
    private let iconSizes: [IconSize] = [
        IconSize(size: 40, label: "iPhone 40pt (80x80)"),
        IconSize(size: 60, label: "iPhone 60pt (120x120)"),
        IconSize(size: 76, label: "iPad 76pt (152x152)"),
        IconSize(size: 83.5, label: "iPad Pro 83.5pt (167x167)"),
        IconSize(size: 120, label: "iPhone 120pt (240x240)"),
        IconSize(size: 152, label: "iPad 152pt (304x304)"),
        IconSize(size: 167, label: "iPad Pro 167pt (334x334)"),
        IconSize(size: 180, label: "iPhone 180pt (360x360)"),
        IconSize(size: 1024, label: "App Store 1024pt (1024x1024)")
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(iconSizes, id: \.size) { icon in
                    iconCard(size: icon.size, label: icon.label)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func iconCard(size: CGFloat, label: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.primary.opacity(0.15), radius: 4, x: 0, y: 2)

                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            Text(label)
                .font(.footnote)
                .foregroundColor(Color.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: size * 2)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    IconPreview()
        .preferredColorScheme(.light)
    IconPreview()
        .preferredColorScheme(.dark)
}

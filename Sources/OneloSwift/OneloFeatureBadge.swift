import SwiftUI

/// A pill badge that renders automatically for New / Beta / Coming Soon feature statuses.
/// Returns an empty view for all other statuses.
///
/// Usage:
///   OneloFeatureBadge(feature: onelo.features.feature("chat"))
///   OneloFeatureBadge(status: .new)
public struct OneloFeatureBadge: View {
    public let status: FeatureStatus

    public init(feature: FeatureState) {
        self.status = feature.status
    }

    public init(status: FeatureStatus) {
        self.status = status
    }

    public var body: some View {
        if let label = FeatureState(name: "", status: status).badgeLabel {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(backgroundColor)
                .clipShape(Capsule())
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .new:          return Color(red: 0.78, green: 0.55, blue: 1.0)   // purple-300
        case .beta:         return Color(red: 0.56, green: 0.84, blue: 1.0)   // sky-300
        case .coming_soon:  return Color(red: 1.0,  green: 0.80, blue: 0.42)  // amber-300
        default:            return .clear
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .new:          return Color(red: 0.78, green: 0.55, blue: 1.0).opacity(0.15)
        case .beta:         return Color(red: 0.56, green: 0.84, blue: 1.0).opacity(0.15)
        case .coming_soon:  return Color(red: 1.0,  green: 0.80, blue: 0.42).opacity(0.15)
        default:            return .clear
        }
    }
}

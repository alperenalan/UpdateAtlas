#if DEBUG
import SwiftUI

struct DebugBuildBadge: View {
    var body: some View {
        Text("Debug build")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.14), in: Capsule())
            .accessibilityLabel(Text("Debug build"))
    }
}
#endif

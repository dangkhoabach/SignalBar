import SwiftUI

/// Settings, pinned under the sidebar's list as in the author's other apps:
/// below a line, in the same place however long the list grows. Drawn like a
/// sidebar row, with the selection's accent pill while Settings is open.
struct SidebarSettingsRow: View {
    var title = Text("Settings")
    var systemImage = "gearshape"
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                // Icon column and spacing as the list's own rows, so the
                // titles line up.
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(width: 22)
                    title.lineLimit(1)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(background, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}

import SwiftUI

struct TopTabBarView: View {
    @Binding var selectedTab: AppTab
    @Namespace private var ns
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases) { tab in
                Button(action: { selectedTab = tab }) {
                    Image(systemName: tab.iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(selectedTab == tab ? .white : .primary.opacity(0.7))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 28)
                        .background(
                            ZStack {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .matchedGeometryEffect(id: "tab", in: ns)
                                        .shadow(color: .blue.opacity(0.3), radius: 5, y: 3)
                                }
                            }
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        .frame(maxWidth: 180)
    }
}

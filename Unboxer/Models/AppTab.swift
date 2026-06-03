import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, settings
    
    var id: Self { self }
    
    var iconName: String {
        self == .dashboard ? "square.grid.2x2.fill" : "gearshape.fill"
    }
}

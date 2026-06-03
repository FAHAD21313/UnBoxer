import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, backups, settings
    
    var id: Self { self }
    
    var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .backups:   return "archivebox.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}

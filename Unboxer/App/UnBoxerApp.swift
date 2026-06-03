//
// UnBoxerApp.swift
// UnBoxer
//

import SwiftUI

@main
struct UnBoxerApp: App {
    @StateObject private var pairingManager = PairingManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pairingManager)
        }
    }
}

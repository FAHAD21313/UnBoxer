//
// ContentView.swift
// UnBoxer
//

import SwiftUI

struct ContentView: View {
    @State private var currentTab: AppTab = .dashboard
    @State private var animateBg = false
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // Dynamic Liquid Gradient Background
            ZStack {
                Color(.systemBackground)
                
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.3), .cyan.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 350, height: 350)
                    .offset(x: animateBg ? -90 : 90, y: animateBg ? -120 : -30)
                
                Circle()
                    .fill(LinearGradient(colors: [.purple.opacity(0.25), .pink.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 400, height: 400)
                    .offset(x: animateBg ? 120 : -70, y: animateBg ? 80 : -160)
            }
            .blur(radius: 65)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                    animateBg.toggle()
                }
            }
            
            // Main Container (left-aligned title formatting for English layout)
            TabView(selection: $currentTab) {
                DashboardView()
                    .tag(AppTab.dashboard)
                
                BackupsView()
                    .tag(AppTab.backups)
                
                SettingsView()
                    .tag(AppTab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
            
            // Floating Tab Bar
            VStack {
                TopTabBarView(selectedTab: $currentTab)
                    .padding(.top, 28)
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentTab)
    }
}

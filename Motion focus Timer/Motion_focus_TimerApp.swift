//
//  Motion_focus_TimerApp.swift
//  Motion focus Timer
//
//  Created by Fenuku kekeli on 8/29/25.
//
import SwiftUI
import StoreKit

@main
struct Motion_focus_TimerApp: App {
    @StateObject private var sessionManager = SessionManager()
    
    @AppStorage("launchCount") private var launchCount = 0
    @AppStorage("didRequestReview") private var didRequestReview = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .onAppear {
                    sessionManager.requestNotificationPermission()
                    sessionManager.restoreSession()
                    
                    handleReviewRequest()
                }
        }
    }
    
    // MARK: - Review Logic
    private func handleReviewRequest() {
        launchCount += 1
        
        // Ask only once, on 2nd launch
        if launchCount == 2 && !didRequestReview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                requestReview()
            }
        }
    }
    
    private func requestReview() {
        guard let scene = UIApplication.shared
            .connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        
        SKStoreReviewController.requestReview(in: scene)
        didRequestReview = true
    }
}

//
//  Motion_focus_TimerApp.swift
//  Motion focus Timer
//
//  Created by Fenuku kekeli on 8/29/25.
//

import SwiftUI

@main
struct Motion_focus_TimerApp: App {
    @StateObject private var sessionManager = SessionManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .onAppear {
                    sessionManager.requestNotificationPermission()
                    sessionManager.restoreSession()
                }
        }
    }
}

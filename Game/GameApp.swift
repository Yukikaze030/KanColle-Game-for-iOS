//
//  GameApp.swift
//  Game
//
//  Created by Haozhe on 2026/7/25.
//

import SwiftUI

@main
struct GameApp: App {
    @UIApplicationDelegateAdaptor(GameAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

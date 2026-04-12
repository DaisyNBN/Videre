//
//  MainTableView.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {

            ContentView()
                .tabItem {
                    Label("Live",
                          systemImage: "waveform")
                }

            ScanView()
                .tabItem {
                    Label("Scan",
                          systemImage: "cube.transparent")
                }
        }
    }
}

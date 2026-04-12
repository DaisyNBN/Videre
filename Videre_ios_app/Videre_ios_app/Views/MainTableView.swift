//
//  MainTableView.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import SwiftUI

private enum MainTabSelection: Hashable {
    case navigate
    case scan
}

struct MainTabView: View {
    @State private var selectedTab: MainTabSelection = .navigate

    var body: some View {
        TabView(selection: $selectedTab) {

            ContentView {
                selectedTab = .scan
            }
                .tag(MainTabSelection.navigate)
                .tabItem {
                    Label("Navigate",
                          systemImage: "location.viewfinder")
                }

            ScanView()
                .tag(MainTabSelection.scan)
                .tabItem {
                    Label("Scan",
                          systemImage: "cube.transparent")
                }
        }
    }
}

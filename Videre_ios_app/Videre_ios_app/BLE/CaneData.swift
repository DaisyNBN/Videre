//
//  CaneData.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

struct CaneData: Codable {
    let distance_cm:  Int
    let zone:         Int
    let alert_count:  Int
    let crowd_mode:   Bool
    let battery:      Int
    let mode:         Int
    let buzzer_on:    Bool
    let button:       String
    let button_id:    String
}

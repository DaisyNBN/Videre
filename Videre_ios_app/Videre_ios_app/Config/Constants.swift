//
//  Constants.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//
import Foundation

struct Constants {
    static let bleServiceUUID        = "FFE0"
    static let bleCharacteristicUUID = "FFE1"

    /// No Supabase HTTP writes (edge fn, REST insert, storage). Logs instead.
    static let supabaseDryRun = true

    /// Dry-run log lines only — shape your Express API should match.
    static let apiLogBaseURL = "http://localhost:3000/api"
}

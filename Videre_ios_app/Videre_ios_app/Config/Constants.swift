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

    /// If true, API requests are logged but not sent.
    static let apiDryRun = false

    /// Dry-run log lines only — shape your deployed Express API.
    static let apiLogBaseURL: String = {
        let trimmed = Secrets.apiURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noTrailingSlash = trimmed.hasSuffix("/")
            ? String(trimmed.dropLast())
            : trimmed
        return noTrailingSlash.hasSuffix("/api")
            ? noTrailingSlash
            : "\(noTrailingSlash)/api"
    }()
}

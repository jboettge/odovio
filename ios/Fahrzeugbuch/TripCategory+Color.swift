import SwiftUI

extension TripCategory {
    /// Farbe der Kategorie (UI). Getrennt von `Models.swift`, damit die Modelle ohne SwiftUI testbar sind.
    var color: Color {
        switch self {
        case .business: .orange
        case .personal: .gray
        case .commute: .blue
        case .field: .purple
        case .unknown: .yellow
        }
    }
}

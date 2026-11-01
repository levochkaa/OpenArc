// BrowserUpdateToast.swift

import Foundation

// MARK: - BrowserUpdateToast

struct BrowserUpdateToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let actionTitle: String
}

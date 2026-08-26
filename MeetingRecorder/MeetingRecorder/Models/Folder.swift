//
//  Folder.swift
//  MeetingRecorder
//
//  View-layer value type for a folder.
//

import Foundation

struct Folder: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentFolderID: UUID?
    var children: [Folder]

    static func == (lhs: Folder, rhs: Folder) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

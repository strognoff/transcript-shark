//
//  FolderRecord.swift
//  MeetingRecorder
//
//  SwiftData persistent model for a folder.
//

import Foundation
import SwiftData

@Model
final class FolderRecord {

    @Attribute(.unique) var id: UUID
    var name: String
    var parentFolderID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentFolderID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.createdAt = Date()
    }
}

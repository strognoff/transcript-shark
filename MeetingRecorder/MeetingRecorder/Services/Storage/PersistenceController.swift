//
//  PersistenceController.swift
//  MeetingRecorder
//
//  Owns the SwiftData ModelContainer.
//  Store location: ~/Library/Application Support/MeetingRecorder/Database/meetings.sqlite
//

import SwiftData
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "PersistenceController")

@MainActor
final class PersistenceController {

    static let shared = PersistenceController()

    let container: ModelContainer

    /// Base URL for resolving relative file paths stored in MeetingRecord.
    static let baseURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("MeetingRecorder")
    }()

    private init() {
        let dbDir = Self.baseURL.appendingPathComponent("Database")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let storeURL = dbDir.appendingPathComponent("meetings.sqlite")

        let schema = Schema([MeetingRecord.self, FolderRecord.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)

        do {
            container = try ModelContainer(for: schema, configurations: config)
            logger.info("PersistenceController: store at \(storeURL.path)")
        } catch {
            // In development, delete and recreate on schema conflict
            logger.error("PersistenceController: failed to open store — \(error.localizedDescription). Recreating.")
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            container = try! ModelContainer(for: schema, configurations: config)
        }
    }
}

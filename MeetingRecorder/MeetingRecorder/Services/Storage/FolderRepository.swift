//
//  FolderRepository.swift
//  MeetingRecorder
//
//  SwiftData-backed repository for folders.
//

import Foundation
import SwiftData
import Observation
import OSLog

private let logger = Logger(subsystem: "com.transcript-shark.MeetingRecorder", category: "FolderRepository")

@Observable
@MainActor
final class FolderRepository {

    private(set) var folders: [Folder] = []

    private let context: ModelContext

    init(context: ModelContext = PersistenceController.shared.container.mainContext) {
        self.context = context
    }

    // MARK: - Load

    func reload() {
        let descriptor = FetchDescriptor<FolderRecord>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            let records = try context.fetch(descriptor)
            folders = buildHierarchy(from: records)
            logger.info("FolderRepository: loaded \(records.count) folders")
        } catch {
            logger.error("FolderRepository: fetch failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Mutations

    @discardableResult
    func createFolder(name: String, parentID: UUID? = nil) -> Folder {
        let record = FolderRecord(name: name, parentFolderID: parentID)
        context.insert(record)
        try? context.save()
        reload()
        return Folder(id: record.id, name: record.name, parentFolderID: record.parentFolderID, children: [])
    }

    func renameFolder(_ folder: Folder, to name: String) {
        guard let record = fetchRecord(id: folder.id) else { return }
        record.name = name
        try? context.save()
        reload()
    }

    func deleteFolder(_ folder: Folder, deleteMeetings: Bool, meetingRepo: MeetingRepository) {
        // Collect all descendant folder IDs (including the folder itself)
        let allDescendants = allDescendantIDs(of: folder.id, in: allFlatFolders())
        let allIDs = allDescendants + [folder.id]

        // Handle meetings in each folder
        for fid in allIDs {
            let affected = meetingRepo.meetings(inFolder: fid)
            for meeting in affected {
                if deleteMeetings {
                    meetingRepo.delete(meeting)
                } else {
                    meetingRepo.move(meeting, toFolder: nil)
                }
            }
        }

        // Delete folder records from bottom up (descendants first)
        let records = (try? context.fetch(FetchDescriptor<FolderRecord>())) ?? []
        for record in records where allIDs.contains(record.id) {
            context.delete(record)
        }
        try? context.save()
        reload()
    }

    func moveFolder(_ folder: Folder, toParent parentID: UUID?) {
        guard let record = fetchRecord(id: folder.id) else { return }
        // Prevent circular references
        if let parentID, allDescendantIDs(of: folder.id, in: allFlatFolders()).contains(parentID) {
            logger.warning("FolderRepository: cannot move folder into its own descendant")
            return
        }
        record.parentFolderID = parentID
        try? context.save()
        reload()
    }

    // MARK: - Queries

    func rootFolders() -> [Folder] {
        folders.filter { $0.parentFolderID == nil }
    }

    // MARK: - Private helpers

    private func fetchRecord(id: UUID) -> FolderRecord? {
        try? context.fetch(
            FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func buildHierarchy(from records: [FolderRecord]) -> [Folder] {
        // Build a flat map of id -> Folder (no children yet)
        var map: [UUID: Folder] = [:]
        for r in records {
            map[r.id] = Folder(id: r.id, name: r.name, parentFolderID: r.parentFolderID, children: [])
        }

        // Attach children
        var roots: [Folder] = []
        var childrenMap: [UUID: [Folder]] = [:]
        for r in records {
            if let pid = r.parentFolderID {
                childrenMap[pid, default: []].append(map[r.id]!)
            } else {
                roots.append(map[r.id]!)
            }
        }

        // Recursively populate children
        func populate(_ folder: Folder) -> Folder {
            let kids = (childrenMap[folder.id] ?? []).map { populate($0) }
            return Folder(id: folder.id, name: folder.name, parentFolderID: folder.parentFolderID, children: kids)
        }

        return roots.map { populate($0) }
    }

    private func allFlatFolders() -> [Folder] {
        var result: [Folder] = []
        func collect(_ f: Folder) {
            result.append(f)
            for child in f.children { collect(child) }
        }
        for root in folders { collect(root) }
        return result
    }

    private func allDescendantIDs(of id: UUID, in flat: [Folder]) -> [UUID] {
        var result: [UUID] = []
        let directChildren = flat.filter { $0.parentFolderID == id }
        for child in directChildren {
            result.append(child.id)
            result += allDescendantIDs(of: child.id, in: flat)
        }
        return result
    }
}

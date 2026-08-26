//
//  SidebarView.swift
//  MeetingRecorder
//
//  Left column: Library section + Folders hierarchy.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {

    @Binding var selection: SidebarFilter
    var folderRepo: FolderRepository
    var meetingRepo: MeetingRepository

    @State private var renamingFolder: Folder? = nil
    @State private var renameText: String = ""
    @State private var showNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var newFolderParentID: UUID? = nil

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Meetings", systemImage: "tray.full")
                    .tag(SidebarFilter.allMeetings)
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarFilter.today)
                Label("This Week", systemImage: "calendar")
                    .tag(SidebarFilter.thisWeek)
            }

            Section("Folders") {
                ForEach(folderRepo.rootFolders()) { folder in
                    FolderRowView(
                        folder: folder,
                        selection: $selection,
                        folderRepo: folderRepo,
                        meetingRepo: meetingRepo,
                        onRename: { f in
                            renamingFolder = f
                            renameText = f.name
                        },
                        onNewSubfolder: { parentID in
                            newFolderParentID = parentID
                            newFolderName = ""
                            showNewFolderAlert = true
                        }
                    )
                }

                Button {
                    newFolderParentID = nil
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Meeting Recorder")
        .sheet(item: $renamingFolder) { folder in
            RenameSheetView(name: $renameText) {
                folderRepo.renameFolder(folder, to: renameText)
                renamingFolder = nil
            } onCancel: {
                renamingFolder = nil
            }
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    folderRepo.createFolder(name: trimmed, parentID: newFolderParentID)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Folder row (recursive)

private struct FolderRowView: View {
    let folder: Folder
    @Binding var selection: SidebarFilter
    var folderRepo: FolderRepository
    var meetingRepo: MeetingRepository
    let onRename: (Folder) -> Void
    let onNewSubfolder: (UUID) -> Void

    @State private var isExpanded: Bool = true
    @State private var isDropTargeted: Bool = false

    var body: some View {
        if folder.children.isEmpty {
            Label(folder.name, systemImage: isDropTargeted ? "folder.fill.badge.plus" : "folder")
                .tag(SidebarFilter.folder(folder.id))
                .contextMenu { contextMenuItems }
                .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(folder.children) { child in
                    FolderRowView(
                        folder: child,
                        selection: $selection,
                        folderRepo: folderRepo,
                        meetingRepo: meetingRepo,
                        onRename: onRename,
                        onNewSubfolder: onNewSubfolder
                    )
                }
            } label: {
                Label(folder.name, systemImage: isDropTargeted ? "folder.fill.badge.plus" : "folder")
                    .tag(SidebarFilter.folder(folder.id))
                    .contextMenu { contextMenuItems }
            }
            .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: uuidString),
                  let meeting = meetingRepo.meetings.first(where: { $0.id == id })
            else { return }
            DispatchQueue.main.async {
                meetingRepo.move(meeting, toFolder: folder.id)
            }
        }
        return true
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Rename") { onRename(folder) }
        Button("New Subfolder") { onNewSubfolder(folder.id) }
        Divider()
        Button("Delete", role: .destructive) {
            folderRepo.deleteFolder(folder, deleteMeetings: false, meetingRepo: meetingRepo)
        }
    }
}

// MARK: - Rename sheet

private struct RenameSheetView: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}

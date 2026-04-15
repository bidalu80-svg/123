import SwiftUI

struct MemoryManagementScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var showClearAllConfirm = false
    @State private var showDeleteSelectedConfirm = false

    var body: some View {
        List(selection: $selectedIDs) {
            Section("记忆管理") {
                Text("你可以保留重要记忆，也可以按条删除或一键清空全部记忆。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.memoryEntries.isEmpty {
                Section("当前状态") {
                    Text("暂无跨会话记忆")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("记忆条目（\(viewModel.memoryEntries.count)）") {
                    ForEach(viewModel.memoryEntries) { item in
                        memoryRow(item)
                            .tag(item.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("删除", role: .destructive) {
                                    Task {
                                        await viewModel.removeMemoryEntry(id: item.id)
                                        selectedIDs.remove(item.id)
                                    }
                                }
                            }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("记忆管理")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !viewModel.memoryEntries.isEmpty {
                    Button(editMode == .active ? "完成" : "选择") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            editMode = editMode == .active ? .inactive : .active
                            if editMode == .inactive {
                                selectedIDs = []
                            }
                        }
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode == .active && !selectedIDs.isEmpty {
                    Button("删除选中", role: .destructive) {
                        showDeleteSelectedConfirm = true
                    }
                }

                Button("清空全部", role: .destructive) {
                    showClearAllConfirm = true
                }
                .disabled(viewModel.memoryEntries.isEmpty)
            }
        }
        .confirmationDialog("清空全部记忆？", isPresented: $showClearAllConfirm) {
            Button("清空全部", role: .destructive) {
                Task {
                    await viewModel.clearAllMemoryEntries()
                    selectedIDs = []
                    editMode = .inactive
                }
            }
        } message: {
            Text("该操作不可撤销。")
        }
        .confirmationDialog("删除选中记忆？", isPresented: $showDeleteSelectedConfirm) {
            Button("删除选中", role: .destructive) {
                let ids = Array(selectedIDs)
                Task {
                    await viewModel.removeMemoryEntries(ids: ids)
                    selectedIDs = []
                    editMode = .inactive
                }
            }
        } message: {
            Text("将删除 \(selectedIDs.count) 条记忆。")
        }
        .task {
            await viewModel.refreshMemoryEntries()
        }
        .refreshable {
            await viewModel.refreshMemoryEntries()
        }
    }

    private func memoryRow(_ item: ConversationMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.body)
                .foregroundStyle(.primary)

            Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

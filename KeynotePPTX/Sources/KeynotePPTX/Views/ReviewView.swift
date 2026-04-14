import SwiftUI

enum ReviewFilter: String, CaseIterable {
    case all = "All"
    case needsReview = "Needs review"
    case confirmed = "Confirmed"
}

struct ReviewView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: ReviewFilter = .all
    @State private var showPatchOptions = false

    private var filteredIndices: [Int] {
        appState.mappingRows.indices.filter { i in
            let row = appState.mappingRows[i]
            switch filter {
            case .all: return true
            case .needsReview: return row.selectedChoice == .skip && !row.topCandidates.isEmpty
            case .confirmed: return row.selectedChoice != .skip
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                Label("\(appState.confirmedCount) confirmed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(appState.skippedCount) skipped", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Filter", selection: $filter) {
                    ForEach(ReviewFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button("Confirm all visible") {
                    for i in filteredIndices {
                        if appState.mappingRows[i].selectedChoice == .skip,
                           let first = appState.mappingRows[i].topCandidates.first {
                            appState.mappingRows[i].selectedChoice = .keynoteFile(filename: first.keynoteFilename)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button("Export →") {
                    showPatchOptions = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.confirmedCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Row list
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(filteredIndices, id: \.self) { i in
                        ReviewRowView(rowIndex: i)
                        Divider()
                    }
                }
            }
        }
        .sheet(isPresented: $showPatchOptions) {
            PatchOptionsView()
        }
    }
}

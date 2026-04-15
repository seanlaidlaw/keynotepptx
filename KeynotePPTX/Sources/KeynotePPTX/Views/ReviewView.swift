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
    @State private var filteredIndices: [Int] = []
    @State private var exactMatchIndices: [Int] = []
    @State private var showExactMatches = false
    @AppStorage("hasSeenReviewOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var showSlideCountAlert = false

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
                LazyVStack(spacing: 8, pinnedViews: []) {
                    ForEach(filteredIndices, id: \.self) { i in
                        ReviewRowView(rowIndex: i)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showPatchOptions) {
            PatchOptionsView()
        }
        .sheet(isPresented: $showOnboarding) {
            ReviewOnboardingView {
                hasSeenOnboarding = true
                showOnboarding = false
            }
        }
        .alert("Slide count mismatch", isPresented: $showSlideCountAlert) {
            Button("Continue anyway", role: .none) { }
        } message: {
            if let m = appState.slideCountMismatch {
                Text("The PowerPoint has \(m.pptxCount) slide\(m.pptxCount == 1 ? "" : "s") but the Keynote has \(m.keynoteCount). They may not be from the same source — review matches carefully.")
            }
        }
        .task {
            updateFilteredIndices()
            if !hasSeenOnboarding { showOnboarding = true }
            if appState.slideCountMismatch != nil { showSlideCountAlert = true }
        }
        .onChange(of: filter) { updateFilteredIndices() }
        .onChange(of: appState.confirmedCount) { updateFilteredIndices() }
        .onChange(of: appState.mappingRows.count) { updateFilteredIndices() }
    }

    private func updateFilteredIndices() {
        // Rows with a single candidate at delta 0 are unambiguous perfect matches —
        // partition them into their own collapsed section so they don't clutter review.
        exactMatchIndices = appState.mappingRows.indices.filter { i in
            let row = appState.mappingRows[i]
            return row.topCandidates.count == 1 && row.topCandidates[0].aHashDistance == 0
        }
        let exactSet = Set(exactMatchIndices)

        filteredIndices = appState.mappingRows.indices.filter { i in
            guard !exactSet.contains(i) else { return false }
            let row = appState.mappingRows[i]
            switch filter {
            case .all:         return true
            case .needsReview: return row.selectedChoice == .skip && !row.topCandidates.isEmpty
            case .confirmed:   return row.selectedChoice != .skip
            }
        }
    }
}

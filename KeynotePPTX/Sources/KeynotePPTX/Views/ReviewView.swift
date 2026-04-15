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
            // Toolbar — liquid glass material
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
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider() }

            // Row list
            ScrollView {
                LazyVStack(spacing: 20, pinnedViews: []) {
                    ForEach(filteredIndices, id: \.self) { i in
                        ReviewRowView(rowIndex: i)
                            .reviewCardStyle()
                    }

                    if !exactMatchIndices.isEmpty && filter != .needsReview {
                        ExactMatchesSectionView(
                            indices: exactMatchIndices,
                            isExpanded: $showExactMatches
                        )
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
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
        // A row is an "exact match" when its best candidate has Δ0 — perfect hash match.
        // We don't require count == 1; there may be other non-zero candidates alongside.
        exactMatchIndices = appState.mappingRows.indices.filter { i in
            appState.mappingRows[i].topCandidates.first?.aHashDistance == 0
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

// MARK: - Exact matches collapsible section

private struct ExactMatchesSectionView: View {
    let indices: [Int]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.callout.bold())
                        .contentTransition(.symbolEffect(.replace))
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("\(indices.count) exact match\(indices.count == 1 ? "" : "es")")
                        .font(.callout.bold())
                    Text("—")
                        .foregroundStyle(.secondary)
                    Text("auto-confirmed, no review needed")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("click to \(isExpanded ? "hide" : "show")")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            }

            if isExpanded {
                ForEach(indices, id: \.self) { i in
                    ReviewRowView(rowIndex: i)
                        .reviewCardStyle()
                }
            }
        }
    }
}

// MARK: - Glass card style

extension View {
    @ViewBuilder
    func reviewCardStyle() -> some View {
        if #available(macOS 26, *) {
            self
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .glassEffect(in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

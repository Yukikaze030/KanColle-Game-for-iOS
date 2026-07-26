import SwiftUI

enum QuestListFilter: String, CaseIterable, Identifiable {
    case accepted = "已接"
    case trackable = "可追踪"
    case completed = "已完成"
    case all = "全部"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .accepted: "checklist"
        case .trackable: "scope"
        case .completed: "checkmark.seal.fill"
        case .all: "tray.full.fill"
        }
    }
}

struct QuestFilterBar: View {
    @Binding var selection: QuestListFilter
    let counts: [QuestListFilter: Int]
    var vertical = false

    var body: some View {
        if vertical {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(QuestListFilter.allCases) { filter in
                    Button {
                        selection = filter
                    } label: {
                        filterLabel(filter)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(selection == filter ? .accentColor : .secondary)
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuestListFilter.allCases) { filter in
                        Button {
                            selection = filter
                        } label: {
                            filterLabel(filter)
                        }
                        .buttonStyle(.bordered)
                        .tint(selection == filter ? .accentColor : .secondary)
                        .accessibilityAddTraits(selection == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 1)
            }
            .accessibilityLabel("任务筛选")
        }
    }

    private func filterLabel(_ filter: QuestListFilter) -> some View {
        Label {
            Text("\(filter.rawValue) \(counts[filter, default: 0])")
                .lineLimit(1)
        } icon: {
            Image(systemName: filter.systemImage)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 30)
        .accessibilityLabel("\(filter.rawValue)，\(counts[filter, default: 0]) 项")
    }
}

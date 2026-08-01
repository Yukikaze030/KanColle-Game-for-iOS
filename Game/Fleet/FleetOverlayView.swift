import SwiftUI
import GameCore

/// Read-only fleet dashboard presented above the live game WebView.
/// The caller owns state and dismissal; presenting this view never recreates the browser.
struct FleetOverlayView: View {
    let gameState: GameDataState
    let timers: [GameTimer]
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedDeckID: Int?

    init(
        gameState: GameDataState,
        timers: [GameTimer] = [],
        selectedDeckID: Int? = nil,
        onClose: @escaping () -> Void
    ) {
        self.gameState = gameState
        self.timers = timers
        self.onClose = onClose
        _selectedDeckID = State(initialValue: selectedDeckID)
    }

    private var decks: [FleetDeck] {
        gameState.fleet.decks.values.sorted { $0.id < $1.id }
    }

    private var effectiveDeckID: Int? {
        if let selectedDeckID, gameState.fleet.decks[selectedDeckID] != nil {
            return selectedDeckID
        }
        return decks.first?.id
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()

                VStack(spacing: 10) {
                    header
                    if decks.isEmpty {
                        emptyState
                    } else if horizontalSizeClass == .regular && proxy.size.width >= 720 {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: decks.map(\.id), initial: true) { _, ids in
            if selectedDeckID == nil || !ids.contains(selectedDeckID ?? -1) {
                selectedDeckID = ids.first
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("舰队", systemImage: "person.3.fill")
                .font(.headline)
            if let admiral = gameState.fleet.admiral {
                Text(admiral.nickname.isEmpty ? "提督" : admiral.nickname)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("数据 #\(gameState.revision)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: onClose) {
                Label("关闭", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("关闭覆盖层并返回游戏")
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 8) {
            deckPicker
            ScrollView {
                VStack(spacing: 10) {
                    selectedFleetCard
                    TimerOverlayView(timers: timers)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(decks, id: \.id) { deck in
                        Button {
                            selectedDeckID = deck.id
                        } label: {
                            HStack {
                                Image(systemName: gameState.fleet.containsHeavyDamage(inDeck: deck.id)
                                      ? "exclamationmark.triangle.fill" : "person.3.fill")
                                Text(deck.name.isEmpty ? "第\(deck.id)舰队" : deck.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(gameState.fleet.ships(inDeck: deck.id).count)")
                                    .monospacedDigit()
                            }
                            .foregroundStyle(gameState.fleet.containsHeavyDamage(inDeck: deck.id) ? .red : .primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(
                                effectiveDeckID == deck.id ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 220)

            ScrollView {
                VStack(spacing: 10) {
                    selectedFleetCard
                    TimerOverlayView(timers: timers)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var deckPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(decks, id: \.id) { deck in
                    Button {
                        selectedDeckID = deck.id
                    } label: {
                        HStack(spacing: 6) {
                            if gameState.fleet.containsHeavyDamage(inDeck: deck.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            Text(deck.name.isEmpty ? "第\(deck.id)舰队" : deck.name)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(effectiveDeckID == deck.id ? .accentColor : .secondary)
                    .accessibilityValue(effectiveDeckID == deck.id ? "已选择" : "")
                }
            }
        }
    }

    @ViewBuilder
    private var selectedFleetCard: some View {
        if let deckID = effectiveDeckID, let deck = gameState.fleet.decks[deckID] {
            FleetCardView(
                deck: deck,
                ships: gameState.fleet.ships(inDeck: deckID),
                masterData: gameState.master,
                userItems: gameState.fleet.slotItems,
                repairingShipIDs: Set(
                    gameState.fleet.repairDocks.values.compactMap(\.shipID)
                ),
                headquartersLevel: gameState.fleet.admiral?.level ?? 0
            )
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无舰队数据",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text("进入母港或刷新游戏后，将在这里显示舰队状态。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

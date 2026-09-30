import SwiftUI

/// The app's visual vocabulary: surfaces, numbers, headers, chips and the motion
/// that ties them together. Colours and type live in `Palette.swift`.
///
/// The rules these pieces encode:
///
/// - **One surface.** Everything raised is the same paper at the same radius with
///   the same hairline. Depth comes from the rule, not from a shadow or a wash.
/// - **Colour is information.** A card is only coloured when its colour means
///   something — a reply, a warning, how long a silence has run — and then only
///   as a rule down its leading edge. Decorative tint was removed: when every
///   card was tinted, the tint that mattered was invisible.
/// - **Serif for figures and titles.** A serif numeral among sans labels reads as
///   a headline without having to be large.

extension Theme {
    /// Corner radii, largest to smallest. Deliberately shallow — a nearly-square
    /// corner reads as a document, a pill reads as a control.
    enum Radius {
        static let hero: CGFloat = 18
        static let card: CGFloat = 14
        static let inner: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Space {
        /// The margin every screen's content sits inside.
        static let gutter: CGFloat = 18
    }

    /// The app's springs, so everything that moves shares one tempo.
    ///
    /// The two originals — `snappy` for things that travel, `quick` for things
    /// that only respond — are joined by three that overshoot. Bounce is used the
    /// same way colour is: it means "this thing is a physical object you just
    /// acted on". A card that dips and springs back is a card you pressed; a
    /// count that settles past its target and returns is a count that *changed*
    /// rather than one that was always that number.
    ///
    /// Nothing here bounces for longer than it takes to read the thing that
    /// bounced. `extraBounce` above ~0.3 starts to read as a wobble the user has
    /// to wait out, which is the difference between lively and slow.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.26, extraBounce: 0.01)
        static let quick = Animation.snappy(duration: 0.16)

        /// Things that arrive or leave: a bar sliding up, a card popping into a
        /// list, a lane swapping. Big enough travel to earn a real overshoot.
        static let bouncy = Animation.snappy(duration: 0.4, extraBounce: 0.24)

        /// Small things that react: a chip, a badge, a checkmark, a pressed card.
        /// Fast, with the springiest return in the app — it's over before it can
        /// get in the way.
        static let pop = Animation.spring(response: 0.3, dampingFraction: 0.56)

        /// Figures and meters settling into place — a ring drawing itself, a
        /// number counting up. Slow enough to watch, and it lands twice.
        static let settle = Animation.snappy(duration: 0.62, extraBounce: 0.3)

        /// Glass surfaces forming, morphing and dissolving. Longer and softer than
        /// `bouncy`, with just enough overshoot to read as surface tension.
        static let liquid = Animation.spring(duration: 0.55, bounce: 0.2)
    }
}

// MARK: - Surfaces

/// A raised surface: paper, a hairline, and — when the card's state is worth
/// saying in colour — a rule down its leading edge.
struct Panel: ViewModifier {
    var accent: Color?
    var radius: CGFloat = Theme.Radius.card

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.paperRaised)
            }
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                }
            }
            // Clipped before the border is drawn, so the rule is cut by the
            // card's curve and the stroke stays a clean unbroken outline on top.
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

extension View {
    /// A plain raised surface.
    func panel(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(Panel(accent: nil, radius: radius))
    }

    /// A raised surface whose leading rule states the row's condition.
    func panel(accent: Color, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(Panel(accent: accent, radius: radius))
    }

    /// A surface whose rule is conditional — nil means an unmarked card. One
    /// modifier either way, so a card gaining or losing its rule stays the same
    /// view and the rule animates in, rather than the card being rebuilt.
    func panelAccented(_ accent: Color?, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(Panel(accent: accent, radius: radius))
    }

    /// Press feedback for anything card-shaped, applied through a button style so
    /// the whole card dips as one object.
    func cardButtonStyle() -> some View {
        buttonStyle(CardPress())
    }

    /// The app's standard arrival: scale up from slightly small while fading in.
    /// Paired with `Theme.Motion.bouncy` it reads as the view springing into the
    /// space rather than being cross-faded into it.
    func popIn(anchor: UnitPoint = .center) -> some View {
        transition(LiquidMaterialize(scale: 0.86, anchor: anchor))
    }
}

/// A card dips and springs back while it's held.
///
/// No haptic. The system's controls don't knock on touch-down, and a knock on
/// press fired whenever a scroll happened to start on a card — every flick
/// through a feed buzzed. Haptics in the app mark things that *happened* (a
/// send, a delete, a selection), not fingers landing.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(isPressed: configuration.isPressed,
                  scale: 0.972, dim: 0.82) {
            configuration.label
        }
    }
}

/// The same idea at small-control scale: a deeper dip.
struct BouncyPress: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        PressBody(isPressed: configuration.isPressed,
                  scale: scale, dim: 1) {
            configuration.label
        }
    }
}

/// The shared body behind both press styles.
///
/// It exists as a `View` rather than living in `makeBody` because a `ButtonStyle`
/// can't read the environment directly, and Reduce Motion has to be honoured here
/// above anywhere else in the app: this is the one treatment that fires on
/// essentially every tap. With it on, the dip is dropped and the button reports
/// itself through opacity alone — the *feedback* is kept, only the movement is
/// spent.
private struct PressBody<Label: View>: View {
    let isPressed: Bool
    let scale: CGFloat
    let dim: Double
    @ViewBuilder var label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .scaleEffect(isPressed && !reduceMotion ? scale : 1)
            .opacity(isPressed ? dim : 1)
            // Not the springy `pop`: a card wobbling under a held finger reads
            // as lag. The system's highlight is quick and flat.
            .animation(reduceMotion ? Theme.Motion.quick : Theme.Motion.snappy, value: isPressed)
    }
}

// MARK: - Buttons

extension View {
    /// The one filled action on a surface: clay (or `tint`) glass, white label.
    ///
    /// The white is stated, not inherited. Prominent glass draws a label's *icon*
    /// in the tint colour unless told otherwise, which is how the plus on a clay
    /// "Add Contact" button vanished into the clay behind it.
    func primaryButton(_ tint: Color = .clay) -> some View {
        buttonStyle(.glassProminent)
            .tint(tint)
            .foregroundStyle(.white)
    }

    /// A secondary action beside or below a primary one: clear glass.
    func secondaryButton() -> some View {
        buttonStyle(.glass)
    }

    /// A filled action that sits *on* a glass bar or capsule. Solid rather than
    /// glass: glass on glass is two panes rendering at once, and the inner one
    /// visibly trailed the bar whenever it moved.
    ///
    /// - Parameter label: the label's colour. White suits clay; on a light fill
    ///   such as kraft white reads at about 2:1 and fails contrast, so those
    ///   pass `.paper` instead.
    func filledButton(_ tint: Color = .clay, label: Color = .white) -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(tint)
            .foregroundStyle(label)
    }
}

// MARK: - Screens and lists

extension View {
    /// The ground behind a whole screen, edge to edge: black, ruled as graph
    /// paper. Every state of a screen sits on it — a spinner while searching, an
    /// empty state, a list — so none of them can show the bare window instead.
    func paperScreen() -> some View {
        background {
            GraphPaper()
                .background(Color.paper)
                .ignoresSafeArea()
        }
    }

    /// A `List` laid out as a column of cards. It paints no ground of its own, so
    /// the screen's graph paper shows between the cards.
    func cardList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Cards scrolling under the floating search field and the tab bar
            // stayed sharp and legible there — a company name printed across
            // the search text. The hard edge lays paper under the bars instead
            // of the soft fade, which on this black ground barely showed.
            .scrollEdgeEffectStyle(.hard, for: .all)
            // Rows are as tall as their cards, not padded up to the system's 44pt
            // minimum — a day label in Activity is shorter than that.
            .environment(\.defaultMinListRowHeight, 0)
    }

    /// One card in a `cardList`: no separator, no row fill, the gutter either side.
    func cardRow(top: CGFloat = 4, bottom: CGFloat = 4) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: Theme.Space.gutter,
                                      bottom: bottom, trailing: Theme.Space.gutter))
    }

}

/// Graph paper: faint rules on a square grid, every fourth one a shade
/// stronger, like the axis grid of a chart. It's the ground of the whole app —
/// the same grid the splash draws its curve on.
///
/// A single 4×4-cell tile, rendered once for the life of the app and repeated by
/// the GPU. It used to be a full-screen `Canvas`, which is re-drawn whenever the
/// screen above it is — including under every menu and sheet as it animated.
struct GraphPaper: View {
    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let spacing: CGFloat = 22

    private static let tile: UIImage = {
        let side = spacing * 4
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            cg.setLineWidth(0.5)
            for index in 0..<4 {
                let offset = CGFloat(index) * spacing + 0.25
                cg.setStrokeColor(index == 0
                                  ? UIColor(Color.hairline).withAlphaComponent(0.55).cgColor
                                  : UIColor(Color.grid).cgColor)
                cg.move(to: CGPoint(x: offset, y: 0)); cg.addLine(to: CGPoint(x: offset, y: side))
                cg.move(to: CGPoint(x: 0, y: offset)); cg.addLine(to: CGPoint(x: side, y: offset))
                cg.strokePath()
            }
        }
    }()
}

/// A whole screen that's still loading: a spinner, on paper.
struct LoadingState: View {
    var label: String?

    var body: some View {
        Group {
            if let label { ProgressView(label) } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperScreen()
        .transition(.opacity)
    }
}

/// A spinner as the last row of a list, while its next page loads.
struct LoadingRow: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

/// A list's multi-select mode: whether it's on, and what's ticked.
///
/// Every list with a Select mode used to carry its own copy of the same three
/// functions — enter, enter-by-holding-a-row, exit — with the same haptics and
/// the same spring. This is that, once.
///
/// A class, not a struct, on purpose. A mutating method on a `@State` struct
/// writes the new value back only *after* it returns — outside its own
/// `withAnimation` — so entering and leaving the mode quietly stopped animating.
/// Here the state changes inside the animation, where it belongs.
///
/// The mode is stored as the `List`'s own `EditMode`, handed to it as a real
/// binding by `listRows`, rather than derived into a `.constant`. That's what
/// lets the list switch it on by itself: a two-finger drag down the rows starts
/// the multi-select *and* the mode in one stroke, as it does in Files and Mail.
@Observable
final class ListSelection<ID: Hashable> {
    var editMode: EditMode = .inactive
    var ids = Set<ID>()

    var isSelecting: Bool { editMode.isEditing }
    var count: Int { ids.count }
    func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// From a menu: the mode opens with nothing picked.
    func enter() {
        ids = []
        Haptics.press()
        withAnimation(Theme.Motion.liquid) { editMode = .active }
    }

    /// From a row's context menu: the mode opens with those rows already picked,
    /// which is the whole reason to have asked from *that* row.
    func begin(with ids: Set<ID>) {
        withAnimation(Theme.Motion.liquid) {
            self.ids = ids
            editMode = .active
        }
    }

    func exit() {
        Haptics.tap(0.5)
        withAnimation(Theme.Motion.liquid) {
            editMode = .inactive
            ids = []
        }
    }
}

extension View {
    /// The row interaction every card list in the app shares, done the way the
    /// system's own lists (Files, Mail, Notes) do it — by the `List`, not by
    /// gestures on the rows:
    ///
    /// - a tap opens the row (`open`), and in selection mode ticks it instead;
    /// - a hold lifts the row into its context menu (`menu`), with the list's
    ///   own preview and haptics — or, in selection mode, the menu for
    ///   everything ticked;
    /// - a two-finger drag down the rows enters selection mode and sweeps a
    ///   range into it;
    /// - swipe actions and scrolling are never contested by a row gesture.
    ///
    /// Rows used to be `Button`s with a simultaneous long-press on top. Every
    /// touch that started a scroll pressed the card (a dip, a knock), the
    /// long-press sat in the scroll view's way, a hold raced the context menu
    /// where a row had one, and the mode's `.constant` edit mode left the
    /// two-finger gesture nothing to switch on. Here the rows are plain views
    /// and the cell does all of it.
    ///
    /// Only tagged rows take part (a `ForEach` over the selection's IDs tags its
    /// rows itself), so a header card or a disclosure row in the same `List` is
    /// neither opened, menu'd, nor selectable.
    func listRows<ID: Hashable, MenuContent: View>(
        _ selection: ListSelection<ID>,
        open: @escaping (ID) -> Void,
        @ViewBuilder menu: @escaping (Set<ID>) -> MenuContent
    ) -> some View {
        environment(\.editMode, Binding { selection.editMode } set: { selection.editMode = $0 })
            .contextMenu(forSelectionType: ID.self, menu: menu) { ids in
                // A tap is one row; a primary action on a multi-row set (a
                // keyboard Return over a selection) has no single thing to open.
                guard !selection.isSelecting, ids.count == 1, let id = ids.first else { return }
                open(id)
            }
    }
}

// MARK: - Numbers

/// A metric set the way every metric in the app is set: serif figures over a
/// sans caption, monospaced so digits don't jitter when they change.
struct Metric: View {
    let value: Int
    var caption: String
    var tint: Color = .ink
    var size: CGFloat = 26
    var alignment: HorizontalAlignment = .center

    /// Drives the kick. Held for a beat and released, so the figure overshoots
    /// on the way out and springs back rather than easing to a new size.
    @State private var kicked = false
    /// Whether this metric has already rendered once. `task(id:)` fires on first
    /// appearance as well as on every change, and a screen where every figure
    /// kicks as it loads reads as a glitch rather than as an update.
    @State private var settled = false

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text("\(value)")
                .font(.display(size))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
                // Only the figure kicks, not the caption — scaling the pair would
                // move the baseline of every metric in a row of them.
                .scaleEffect(kicked ? 1.16 : 1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
        .animation(Theme.Motion.settle, value: value)
        .task(id: value) {
            guard settled else { settled = true; return }
            withAnimation(Theme.Motion.pop) { kicked = true }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(Theme.Motion.pop) { kicked = false }
        }
    }
}

/// A thin vertical rule between metrics.
struct MetricDivider: View {
    var height: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: 1, height: height)
    }
}

// MARK: - Headers

/// A section header with an optional count. Uppercase and tracked, so it reads
/// as a label rather than as content.
struct SectionLabel: View {
    let title: String
    var systemImage: String?
    var count: Int?
    var tint: Color = .inkMuted

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.9)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Selector

/// The app's segmented control: the system's own.
///
/// It used to be hand-built — a glass capsule morphing between buttons inside a
/// `GlassEffectContainer`, with a bouncing glyph per segment. It looked the part
/// but re-rendered glass on every switch and never quite moved like the system
/// control beside it in Settings or Mail. `Picker(.segmented)` is what the
/// built-in apps use, and it brings the system's feel, VoiceOver behaviour and
/// Dynamic Type for free. Titles only: the system control shows a title or a
/// glyph per segment, and a title is what these lanes need.
struct SegmentedSelector<Value: Hashable>: View {
    let segments: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Picker("", selection: $selection.animation(Theme.Motion.snappy)) {
            ForEach(segments, id: \.value) { segment in
                Text(segment.title).tag(segment.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Forms

/// The app's form chrome, in one place: paper ground, paper rows.
///
/// Every editor in the app is a `Form` — the system's row layout, keyboard
/// handling and field semantics are worth keeping — but the default grouped
/// background is the neutral grey the rest of the app was moved off. Wrapping
/// rather than modifying is what makes the row colour reachable: `listRowBackground`
/// has to be applied to the rows, so the content is the thing that carries it.
///
/// Use this in place of `Form` everywhere, so a new editor can't quietly ship in
/// the system palette.
struct PaperForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(Color.paperRaised)
        }
        .scrollContentBackground(.hidden)
        .paperScreen()
    }
}

/// The same treatment for the read-only `List`s (a sent mail, a send history).
struct PaperList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowBackground(Color.paperRaised)
        }
        .scrollContentBackground(.hidden)
        .paperScreen()
    }
}

// MARK: - Empty state

/// A compact empty state for use *inside* a scroll view, where
/// `ContentUnavailableView` would demand the whole screen.
struct InlineEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var tint: Color = .inkFaint

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title)
                .font(.display(17))
                .foregroundStyle(.ink)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .panel()
        .popIn()
    }
}

// MARK: - Wrapping layout

/// Lays its children out left to right, wrapping onto a new line when the next
/// one won't fit — for chips, whose count and widths aren't known up front. A
/// horizontal scroll view hid everything past the edge; this shows it all.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                var size = subviews[index].sizeThatFits(.unspecified)
                size.width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

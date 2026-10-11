import AppKit
import SwiftUI

struct NoteGraphView: View {
    @Bindable var workspace: Workspace

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var layout = NoteGraphLayout.empty
    @State private var layoutTask: Task<Void, Never>?
    @State private var relayoutSeed = 0
    @State private var viewport = GraphViewport()
    @State private var hoveredNodeID: URL?
    @State private var isComputingLayout = false
    @State private var filter = GraphFilter()
    @State private var isFilterBarPresented = false
    /// Everything derived from the raw graph, the active filter and the hovered
    /// node (filtered snapshot, label set, connected nodes, ...). Rebuilt only
    /// when one of those inputs changes — never per body evaluation or per
    /// Canvas draw. See `refreshDerivedState`.
    @State private var derived = GraphDerivedState()
    /// Topology key of the layout most recently *scheduled*. Compared against
    /// the current graph so cosmetic changes (filter text, titles) never
    /// reschedule the simulation.
    @State private var scheduledTopology: GraphTopologyKey?
    /// Topology identity of the layout most recently *computed*, used to avoid
    /// re-running the force simulation on selection-only changes. Assigned as
    /// soon as the simulation frames exist, before they are animated in.
    @State private var laidOutTopology: GraphTopologyKey?
    /// Final frame of the most recent force simulation. Re-centering works from
    /// this rather than from `layout`, which may be a mid-animation frame.
    @State private var settledLayout: NoteGraphLayout?

    private let minimumZoom: CGFloat = 0.65
    private let maximumZoom: CGFloat = 2.8
    /// How far beyond the canvas an edge may still be drawn, so strokes that
    /// run along the border are not dropped by the visibility cull.
    private let edgeCullingMargin: CGFloat = 4

    private var rawSnapshot: NoteGraphSnapshot {
        workspace.noteGraph
    }

    /// Snapshot the force layout is computed from. We lay out the *unfiltered*
    /// topology (plus the current selection, which is pinned to center) so that
    /// cosmetic filter changes never trigger a relayout — filtered-out nodes are
    /// simply not drawn. See `scheduleLayout`.
    private var layoutSnapshot: NoteGraphSnapshot {
        rawSnapshot
    }

    /// Graph snapshot with active filters applied (memoized in `derived`).
    private var snapshot: NoteGraphSnapshot {
        derived.snapshot
    }

    private var connectedNodes: [NoteGraphNode] {
        derived.connectedNodes
    }

    private var labeledNodes: [NoteGraphNode] {
        derived.labeledNodes
    }

    /// Nodes exposed to assistive technology, ordered most-connected first so the
    /// graph's hubs are encountered early during VoiceOver navigation.
    private var accessibilityNodes: [NoteGraphNode] {
        derived.accessibilityNodes
    }

    /// Identity of the inputs that actually require a fresh force layout: the raw
    /// node/edge topology, the pinned (selected) node, and the relayout seed.
    /// Filter search text and min-degree are intentionally excluded so typing in
    /// the filter does not relayout or reshuffle the graph.
    private func currentTopologyKey() -> GraphTopologyKey {
        let graph = layoutSnapshot
        return GraphTopologyKey(
            nodeIDs: graph.nodes.map(\.id),
            edgeIDs: graph.edges.map(\.id),
            selectedNodeID: graph.selectedNodeID,
            relayoutSeed: relayoutSeed
        )
    }

    /// Whether the simulation can be skipped for `key` because the settled layout
    /// already covers the same node/edge topology and seed. Only the pinned
    /// (selected) node may differ, which a cheap re-centre handles.
    private func canReuseSettledLayout(for key: GraphTopologyKey) -> Bool {
        guard let previous = laidOutTopology else { return false }
        return previous.nodeIDs == key.nodeIDs
            && previous.edgeIDs == key.edgeIDs
            && previous.relayoutSeed == key.relayoutSeed
    }

    var body: some View {
        Group {
            if rawSnapshot.nodes.isEmpty {
                ContentUnavailableView(
                    "No Graph Yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Create notes and connect them with `[[Wiki Links]]` or local markdown links to map the vault.")
                )
            } else {
                GeometryReader { geometry in
                    ZStack {
                        graphBackdrop

                        graphCanvas(in: geometry.size)

                        if let selectedNode = derived.selectedNode {
                            selectedNodePanel(selectedNode)
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }

                        controlsPanel
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                        // With no filter the derived snapshot equals the raw one
                        // (non-empty here), so "no matches" can only come from a
                        // filter. Checking the filter also keeps the overlay from
                        // flashing before `onAppear` populates `derived`.
                        if !filter.isEmpty, snapshot.nodes.isEmpty {
                            noMatchesOverlay
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !connectedNodes.isEmpty {
                            relatedNotesPanel
                                .padding(20)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(panGesture)
                    .simultaneousGesture(magnificationGesture)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            refreshDerivedState()
            let key = currentTopologyKey()
            scheduledTopology = key
            scheduleLayout(for: key)
        }
        .onDisappear {
            layoutTask?.cancel()
        }
        .onChange(of: workspace.noteGraph) { _, _ in
            refreshDerivedState()
            scheduleLayoutIfTopologyChanged()
        }
        .onChange(of: filter) { _, _ in
            refreshDerivedState()
        }
        .onChange(of: hoveredNodeID) { _, newValue in
            // Hover only changes which extra label is shown; it never re-filters.
            derived.updateLabels(hoveredNodeID: newValue)
        }
        .onChange(of: relayoutSeed) { _, _ in
            scheduleLayoutIfTopologyChanged()
        }
        .onChange(of: derived.snapshot.selectedNodeID) { oldValue, newValue in
            if oldValue != newValue {
                resetViewport()
            }
        }
    }

    /// Rebuilds everything that depends on the raw graph, the filter or the
    /// hovered node. Called from `onAppear` and from the graph/filter `onChange`
    /// handlers only.
    private func refreshDerivedState() {
        derived = GraphDerivedState(
            graph: rawSnapshot,
            filter: filter,
            hoveredNodeID: hoveredNodeID
        )
    }

    private func scheduleLayoutIfTopologyChanged() {
        let key = currentTopologyKey()
        guard key != scheduledTopology else { return }
        scheduledTopology = key
        scheduleLayout(for: key)
    }

    private var noMatchesOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.headline)
            Text("No notes match the current filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Filter") { filter = GraphFilter() }
                .controlSize(.regular)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
    }

    private var graphBackdrop: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            RadialGradient(
                colors: [
                    Color.primary.opacity(0.025),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 640
            )
        }
        .ignoresSafeArea()
    }

    private func graphCanvas(in size: CGSize) -> some View {
        ZStack {
            Canvas { context, canvasSize in
                drawEdges(in: &context, size: canvasSize)
                drawNodes(in: &context, size: canvasSize)
            }
            .allowsHitTesting(false)

            ForEach(labeledNodes) { node in
                if let position = layout.positions[node.id] {
                    nodeLabel(node, position: transformed(position, in: size))
                }
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleNodeTap(at: location, in: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredNodeID = nearestNode(to: location, in: size)?.id
                    case .ended:
                        hoveredNodeID = nil
                    }
                }
                .allowsHitTesting(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note graph")
        .accessibilityRepresentation {
            accessibilityNodeList
        }
    }

    /// A focusable, VoiceOver-navigable representation of the graph nodes layered
    /// over the Canvas rendering (which itself carries no accessibility content).
    /// Each node is a button that announces its title and connection count and
    /// opens the note when activated.
    private var accessibilityNodeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accessibilityNodes) { node in
                    Button {
                        workspace.selectFile(node.url)
                    } label: {
                        Text(node.title)
                    }
                    .accessibilityLabel(node.title)
                    .accessibilityValue(connectionDescription(for: node))
                    .accessibilityHint("Opens this note")
                    .accessibilityAddTraits(snapshot.selectedNodeID == node.id ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func connectionDescription(for node: NoteGraphNode) -> String {
        let count = node.degree
        return count == 1 ? "1 connection" : "\(count) connections"
    }

    private func handleNodeTap(at location: CGPoint, in size: CGSize) {
        guard let node = nearestNode(to: location, in: size) else { return }
        workspace.selectFile(node.url)
    }

    /// Returns the visible node whose drawn circle is nearest the given point.
    ///
    /// The hit radius matches each node's drawn radius (with a small minimum for
    /// tiny nodes), so large hub nodes are tappable out to their visible edge and
    /// clustered nodes resolve to the closest one rather than the first in draw
    /// order. Ties are broken toward larger (higher-degree) nodes.
    private func nearestNode(to location: CGPoint, in size: CGSize) -> NoteGraphNode? {
        let minimumTapRadius: CGFloat = 12
        let selectedNodeID = snapshot.selectedNodeID
        let positions = layout.positions
        var best: (node: NoteGraphNode, distanceSquared: CGFloat, degree: Int)?

        for node in snapshot.nodes {
            guard let position = positions[node.id] else { continue }
            let screenPos = transformed(position, in: size)
            let dx = location.x - screenPos.x
            let dy = location.y - screenPos.y
            let distanceSquared = dx * dx + dy * dy

            let diameter = Self.nodeDiameter(for: node, isSelected: node.id == selectedNodeID)
            let hitRadius = max(diameter / 2, minimumTapRadius)
            guard distanceSquared <= hitRadius * hitRadius else { continue }

            if let current = best {
                let isCloser = distanceSquared < current.distanceSquared
                let isTieButLarger = distanceSquared == current.distanceSquared && node.degree > current.degree
                guard isCloser || isTieButLarger else { continue }
            }

            best = (node, distanceSquared, node.degree)
        }

        return best?.node
    }

    private func drawEdges(in context: inout GraphicsContext, size: CGSize) {
        let selectedNodeID = snapshot.selectedNodeID
        let hoveredNodeID = hoveredNodeID
        let positions = layout.positions
        let visibleRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: -edgeCullingMargin, dy: -edgeCullingMargin)

        // Edges are batched into (at most) three paths by emphasis so the canvas
        // issues three strokes instead of one per edge.
        var selectedEdges = Path()
        var hoveredEdges = Path()
        var normalEdges = Path()

        for edge in snapshot.edges {
            guard let source = positions[edge.source],
                  let target = positions[edge.target] else {
                continue
            }

            let sourcePoint = transformed(source, in: size)
            let targetPoint = transformed(target, in: size)
            guard Self.segmentMayIntersect(visibleRect, from: sourcePoint, to: targetPoint) else {
                continue
            }

            if edge.source == selectedNodeID || edge.target == selectedNodeID {
                selectedEdges.move(to: sourcePoint)
                selectedEdges.addLine(to: targetPoint)
            } else if edge.source == hoveredNodeID || edge.target == hoveredNodeID {
                hoveredEdges.move(to: sourcePoint)
                hoveredEdges.addLine(to: targetPoint)
            } else {
                normalEdges.move(to: sourcePoint)
                normalEdges.addLine(to: targetPoint)
            }
        }

        // Plain edges first so the highlighted ones stay on top.
        if !normalEdges.isEmpty {
            context.stroke(
                normalEdges,
                with: .color(Color.primary.opacity(0.075)),
                style: StrokeStyle(lineWidth: 0.65, lineCap: .round)
            )
        }

        if !hoveredEdges.isEmpty {
            context.stroke(
                hoveredEdges,
                with: .color(Color.primary.opacity(0.22)),
                style: StrokeStyle(lineWidth: 0.65, lineCap: .round)
            )
        }

        if !selectedEdges.isEmpty {
            context.stroke(
                selectedEdges,
                with: .color(Color.primary.opacity(0.28)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
        }
    }

    private func drawNodes(in context: inout GraphicsContext, size: CGSize) {
        let selectedNodeID = snapshot.selectedNodeID
        let connectedNodeIDs = snapshot.connectedNodeIDs
        let hoveredNodeID = hoveredNodeID
        let positions = layout.positions
        let visibleRect = CGRect(origin: .zero, size: size)

        for node in snapshot.nodes {
            guard let position = positions[node.id] else { continue }
            let isSelected = node.id == selectedNodeID
            let isHovered = node.id == hoveredNodeID
            let screenPos = transformed(position, in: size)
            let diameter = Self.nodeDiameter(for: node, isSelected: isSelected)
            let rect = CGRect(
                x: screenPos.x - diameter / 2,
                y: screenPos.y - diameter / 2,
                width: diameter,
                height: diameter
            )

            // The focus ring is the widest decoration; anything beyond it is off-canvas.
            guard rect.insetBy(dx: -6, dy: -6).intersects(visibleRect) else { continue }

            if isSelected {
                let focusRing = rect.insetBy(dx: -5, dy: -5)
                context.stroke(
                    Circle().path(in: focusRing),
                    with: .color(Color.primary.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1.2)
                )
            }

            let fill = Self.nodeFill(
                isSelected: isSelected,
                isHovered: isHovered,
                isConnected: connectedNodeIDs.contains(node.id)
            )
            context.fill(Circle().path(in: rect), with: .color(fill))
            context.stroke(
                Circle().path(in: rect),
                with: .color(Self.nodeStroke(isHighlighted: isSelected || isHovered)),
                style: StrokeStyle(lineWidth: isSelected ? 1.5 : 0.8)
            )
        }
    }

    private func nodeLabel(_ node: NoteGraphNode, position: CGPoint) -> some View {
        let isSelected = snapshot.selectedNodeID == node.id
        let size = Self.nodeDiameter(for: node, isSelected: isSelected)

        return Text(node.title)
            .font(isSelected ? .callout.weight(.semibold) : .caption2.weight(.medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .shadow(color: Color(nsColor: .textBackgroundColor).opacity(0.95), radius: 3)
            .position(x: position.x, y: position.y + size * 0.95 + 8)
            .allowsHitTesting(false)
    }

    private func selectedNodePanel(_ selectedNode: NoteGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.primary.opacity(0.82))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedNode.title)
                        .font(.headline.weight(.semibold))

                    Text(selectedNode.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                statMetric(value: snapshot.nodes.count, title: "Notes")
                graphMetricDivider
                statMetric(value: snapshot.edges.count, title: "Links")
                graphMetricDivider
                statMetric(value: selectedNode.incomingCount, title: "Backlinks")
                graphMetricDivider
                statMetric(value: selectedNode.outgoingCount, title: "Out")
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var controlsPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 4) {
                graphControlButton(systemImage: "minus.magnifyingglass", help: "Zoom Out") {
                    adjustZoom(to: viewport.zoom * 0.88)
                }

                Text("\(Int(viewport.zoom * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42)

                graphControlButton(systemImage: "plus.magnifyingglass", help: "Zoom In") {
                    adjustZoom(to: viewport.zoom * 1.12)
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)

                graphControlButton(systemImage: "scope", help: "Center Graph") {
                    resetViewport()
                }

                graphControlButton(systemImage: "arrow.clockwise", help: "Relayout Graph") {
                    // Bumping the seed changes the topology key, which schedules
                    // a fresh simulation via `onChange(of: relayoutSeed)`.
                    relayoutSeed += 1
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)

                graphControlButton(
                    systemImage: filter.isEmpty
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill",
                    help: filter.isEmpty ? "Filter Graph" : "Active filter — click to edit"
                ) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        isFilterBarPresented.toggle()
                    }
                }

                if isComputingLayout {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            }

            if isFilterBarPresented {
                filterPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !filter.isEmpty {
                    Button("Clear") { filter = GraphFilter() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Title or path", text: $filter.titleSearch)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(filter.minDegree)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(filter.minDegree) },
                        set: { filter.minDegree = Int($0.rounded()) }
                    ),
                    in: 0...10,
                    step: 1
                )
                .controlSize(.small)
            }

        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
    }

    private var relatedNotesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected Notes")
                .font(.subheadline.weight(.semibold))

            ForEach(Array(connectedNodes.prefix(6))) { node in
                Button {
                    workspace.selectFile(node.url)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(
                                snapshot.connectedNodeIDs.contains(node.id)
                                    ? Color.primary.opacity(0.68)
                                    : Color.secondary.opacity(0.45)
                            )
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .lineLimit(1)
                            Text(node.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text("\(node.degree)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
    }

    private func statMetric(value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 48, alignment: .leading)
    }

    private var graphMetricDivider: some View {
        Divider()
            .frame(height: 24)
    }

    private func graphControlButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    nonisolated private static func nodeDiameter(for node: NoteGraphNode, isSelected: Bool) -> CGFloat {
        let clampedDegree = CGFloat(min(max(node.degree, 0), 12))
        let selectionBoost: CGFloat = isSelected ? 4 : 0
        return 7 + sqrt(clampedDegree) * 2 + selectionBoost
    }

    private static func nodeFill(isSelected: Bool, isHovered: Bool, isConnected: Bool) -> Color {
        if isSelected {
            return Color.primary.opacity(0.92)
        }

        if isHovered {
            return Color.primary.opacity(0.78)
        }

        if isConnected {
            return Color.primary.opacity(0.52)
        }

        return Color.primary.opacity(0.23)
    }

    private static func nodeStroke(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return Color(nsColor: .textBackgroundColor).opacity(0.88)
        }

        return Color.primary.opacity(0.2)
    }

    /// Conservative visibility test for an edge (Cohen–Sutherland trivial reject):
    /// a segment is skipped only when both endpoints lie beyond the *same* side
    /// of `rect`, which guarantees it cannot cross the visible area. Segments
    /// whose endpoints are outside on different sides are kept, since they may
    /// still pass through the canvas when zoomed in.
    nonisolated private static func segmentMayIntersect(_ rect: CGRect, from start: CGPoint, to end: CGPoint) -> Bool {
        (outcode(of: start, in: rect) & outcode(of: end, in: rect)) == 0
    }

    nonisolated private static func outcode(of point: CGPoint, in rect: CGRect) -> UInt8 {
        var code: UInt8 = 0

        if point.x < rect.minX {
            code |= 1
        } else if point.x > rect.maxX {
            code |= 2
        }

        if point.y < rect.minY {
            code |= 4
        } else if point.y > rect.maxY {
            code |= 8
        }

        return code
    }

    private func transformed(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let scale = min(size.width, size.height) * 0.34 * viewport.zoom
        return CGPoint(
            x: size.width / 2 + viewport.offset.width + point.x * scale,
            y: size.height / 2 + viewport.offset.height + point.y * scale
        )
    }

    private func adjustZoom(to proposedZoom: CGFloat) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85)) {
            viewport.zoom = min(max(proposedZoom, minimumZoom), maximumZoom)
        }
        viewport.commitZoom()
    }

    private func scheduleLayout(for key: GraphTopologyKey) {
        let snapshot = layoutSnapshot
        layoutTask?.cancel()

        guard !snapshot.nodes.isEmpty else {
            layout = .empty
            settledLayout = nil
            laidOutTopology = key
            isComputingLayout = false
            return
        }

        // When the node/edge topology is unchanged (only the pinned node moved,
        // or the view reappeared), re-center the settled simulation result
        // instead of re-running the O(n²) simulation. This keeps node positions
        // stable (no reshuffle) and avoids a CPU spike on rapid selection
        // changes. Because the running animation task was cancelled above and
        // `settledLayout` is always the simulation's *final* frame, this also
        // works while the previous layout is still animating in.
        if canReuseSettledLayout(for: key),
           let settledLayout,
           let recentered = NoteGraphLayoutEngine.recenter(settledLayout, for: snapshot) {
            let selectionChanged = laidOutTopology?.selectedNodeID != key.selectedNodeID
            withAnimation(selectionChanged ? layoutAnimation : nil) {
                layout = recentered
            }
            laidOutTopology = key
            isComputingLayout = false
            return
        }

        isComputingLayout = true
        let seed = key.relayoutSeed
        let shouldAnimateSimulation = !reduceMotion
        layoutTask = Task {
            let frames = await Task.detached(priority: .userInitiated) {
                NoteGraphLayoutEngine.animationFrames(for: snapshot, relayoutSeed: seed)
            }.value

            guard !Task.isCancelled else { return }

            guard let finalFrame = frames.last else {
                await MainActor.run {
                    isComputingLayout = false
                }
                return
            }

            // Record the result before animating it in, so a selection change
            // during the animation re-centers from the settled frame instead of
            // starting a second full simulation.
            await MainActor.run {
                laidOutTopology = key
                settledLayout = finalFrame
            }

            if shouldAnimateSimulation, let firstFrame = frames.first {
                await MainActor.run {
                    layout = firstFrame
                }

                for frame in frames.dropFirst() {
                    do {
                        try await Task.sleep(for: .milliseconds(24))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        layout = frame
                    }
                }
            } else {
                await MainActor.run {
                    layout = finalFrame
                }
            }

            await MainActor.run {
                isComputingLayout = false
            }
        }
    }

    /// Spring used for lightweight re-centering when the topology is unchanged.
    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    private func resetViewport() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84)) {
            viewport.reset()
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                viewport.offset = CGSize(
                    width: viewport.lastCommittedOffset.width + value.translation.width,
                    height: viewport.lastCommittedOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                viewport.offset = CGSize(
                    width: viewport.lastCommittedOffset.width + value.translation.width,
                    height: viewport.lastCommittedOffset.height + value.translation.height
                )
                viewport.commitOffset()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                viewport.zoom = min(max(viewport.lastCommittedZoom * value, minimumZoom), maximumZoom)
            }
            .onEnded { value in
                viewport.zoom = min(max(viewport.lastCommittedZoom * value, minimumZoom), maximumZoom)
                viewport.commitZoom()
            }
    }
}

struct GraphFilter: Equatable {
    var minDegree: Int = 0
    var titleSearch: String = ""

    var isEmpty: Bool {
        minDegree == 0 && titleSearch.isEmpty
    }
}

/// State derived from the raw graph, the active filter and the hovered node.
///
/// Everything here used to be a computed property re-evaluated on every body
/// evaluation and inside the Canvas draw loops; it is now rebuilt only when one
/// of its inputs changes (see `NoteGraphView.refreshDerivedState`).
private struct GraphDerivedState {
    /// Graph snapshot with active filters applied. Edges are trimmed to only
    /// those whose endpoints both survived the filter so orphan edges don't
    /// get drawn.
    var snapshot: NoteGraphSnapshot = .empty
    /// The selected node, if it survived the filter.
    var selectedNode: NoteGraphNode?
    /// Neighbours of the selected node, most connected first.
    var connectedNodes: [NoteGraphNode] = []
    /// Nodes exposed to assistive technology, most connected first.
    var accessibilityNodes: [NoteGraphNode] = []
    /// Nodes whose labels are always shown: the selection, its closest
    /// neighbours and the graph's biggest hubs (snapshot order).
    var prominentLabeledNodes: [NoteGraphNode] = []
    /// `prominentLabeledNodes` plus the hovered node, if any.
    var labeledNodes: [NoteGraphNode] = []

    private var prominentLabelNodeIDs: Set<URL> = []
    private var nodesByID: [URL: NoteGraphNode] = [:]

    init() {}

    init(graph: NoteGraphSnapshot, filter: GraphFilter, hoveredNodeID: URL?) {
        snapshot = Self.filteredSnapshot(graph, filter: filter)
        nodesByID = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selectedNode = snapshot.selectedNodeID.flatMap { nodesByID[$0] }
        connectedNodes = snapshot.neighbors(of: snapshot.selectedNodeID)
        accessibilityNodes = snapshot.nodes.sorted(by: Self.isMoreProminent)

        var prominentIDs = Set<URL>()
        if let selectedNodeID = snapshot.selectedNodeID {
            prominentIDs.insert(selectedNodeID)
            prominentIDs.formUnion(connectedNodes.prefix(6).map(\.id))
        }
        prominentIDs.formUnion(accessibilityNodes.prefix(4).map(\.id))
        prominentLabelNodeIDs = prominentIDs
        prominentLabeledNodes = snapshot.nodes.filter { prominentIDs.contains($0.id) }

        updateLabels(hoveredNodeID: hoveredNodeID)
    }

    /// Hover only adds (at most) one label on top of the prominent set; it never
    /// re-filters the graph or re-sorts the nodes.
    mutating func updateLabels(hoveredNodeID: URL?) {
        var nodes = prominentLabeledNodes
        if let hoveredNodeID,
           !prominentLabelNodeIDs.contains(hoveredNodeID),
           let hoveredNode = nodesByID[hoveredNodeID] {
            nodes.append(hoveredNode)
        }
        labeledNodes = nodes
    }

    private static func filteredSnapshot(_ base: NoteGraphSnapshot, filter: GraphFilter) -> NoteGraphSnapshot {
        guard !filter.isEmpty else { return base }

        let searchQuery = filter.titleSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        let allowedIDs = Set(base.nodes.compactMap { node -> URL? in
            guard node.degree >= filter.minDegree else { return nil }

            if !searchQuery.isEmpty,
               !node.title.localizedStandardContains(searchQuery),
               !node.relativePath.localizedStandardContains(searchQuery) {
                return nil
            }

            return node.id
        })

        let filteredNodes = base.nodes.filter { allowedIDs.contains($0.id) }
        let filteredEdges = base.edges.filter {
            allowedIDs.contains($0.source) && allowedIDs.contains($0.target)
        }
        let filteredSelected = base.selectedNodeID.flatMap { allowedIDs.contains($0) ? $0 : nil }
        let filteredConnected = base.connectedNodeIDs.intersection(allowedIDs)

        return NoteGraphSnapshot(
            nodes: filteredNodes,
            edges: filteredEdges,
            selectedNodeID: filteredSelected,
            connectedNodeIDs: filteredConnected
        )
    }

    /// Degree descending, then title — shared by the accessibility ordering and
    /// the "most prominent" label picks.
    private static func isMoreProminent(_ lhs: NoteGraphNode, _ rhs: NoteGraphNode) -> Bool {
        if lhs.degree != rhs.degree {
            return lhs.degree > rhs.degree
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Identity of the inputs that require a fresh force layout. Equatable so the
/// view can compare the current graph against the last scheduled layout and
/// skip relayout when only cosmetic filter state changed.
private struct GraphTopologyKey: Equatable {
    let nodeIDs: [URL]
    let edgeIDs: [String]
    let selectedNodeID: URL?
    let relayoutSeed: Int
}

private struct GraphViewport {
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var lastCommittedZoom: CGFloat = 1
    var lastCommittedOffset: CGSize = .zero

    mutating func reset() {
        zoom = 1
        offset = .zero
        lastCommittedZoom = 1
        lastCommittedOffset = .zero
    }

    mutating func commitOffset() {
        lastCommittedOffset = offset
    }

    mutating func commitZoom() {
        lastCommittedZoom = zoom
    }
}

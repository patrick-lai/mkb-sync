import MKBCore
import SwiftUI

/// Drag Macs around to match how they sit on the desk, like System Settings ▸ Displays.
/// Changes are shared with every Mac in the space.
struct LayoutEditorView: View {
    @ObservedObject var model: AppModel
    @State private var dragging: String?
    @State private var dragOrigin = VPoint.zero
    @State private var draft: VPoint?
    @State private var frozen: Viewport?

    struct Viewport: Equatable {
        var bounds: VRect
        var scale: Double
        var inset: CGSize
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let viewport = frozen ?? fit(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                    ForEach(devices) { device in
                        DeviceTile(device: device, scale: viewport.scale, isDragging: dragging == device.id,
                                   isolated: !isAdjacent(device))
                            .position(position(of: device, in: viewport))
                            .gesture(drag(device, viewport: viewport))
                    }
                }
            }
            Divider()
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Drag the Macs to match your desk. Push the cursor off a shared edge to move to the next Mac. Linked Macs are handled by Universal Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.resetLayout() }
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var devices: [LayoutDevice] {
        model.layoutDevices.map { d in
            var d = d
            if d.id == dragging, let draft { d.origin = draft }
            return d
        }
    }

    private func isAdjacent(_ device: LayoutDevice) -> Bool {
        let others = devices.filter { $0.id != device.id }.map(\.frame)
        return others.isEmpty || LayoutMath.isAdjacent(device.frame, to: others, tolerance: 8)
    }

    private func fit(in size: CGSize) -> Viewport {
        let frames = model.layoutDevices.map(\.frame)
        let union = VRect.union(of: frames) ?? VRect(x: 0, y: 0, width: 1440, height: 900)
        // Leave room around the arrangement to drag into.
        let padded = VRect(x: union.minX - union.width * 0.35, y: union.minY - union.height * 0.5,
                           width: union.width * 1.7, height: union.height * 2)
        let scale = min(Double(size.width) / padded.width, Double(size.height) / padded.height)
        let inset = CGSize(width: (Double(size.width) - padded.width * scale) / 2,
                           height: (Double(size.height) - padded.height * scale) / 2)
        return Viewport(bounds: padded, scale: scale, inset: inset)
    }

    private func position(of device: LayoutDevice, in v: Viewport) -> CGPoint {
        let c = device.frame.center
        return CGPoint(x: (c.x - v.bounds.minX) * v.scale + Double(v.inset.width),
                       y: (c.y - v.bounds.minY) * v.scale + Double(v.inset.height))
    }

    private func drag(_ device: LayoutDevice, viewport: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging != device.id {
                    dragging = device.id
                    dragOrigin = device.origin
                    frozen = viewport
                }
                let scale = (frozen ?? viewport).scale
                draft = VPoint(dragOrigin.x + Double(value.translation.width) / scale,
                               dragOrigin.y + Double(value.translation.height) / scale)
            }
            .onEnded { _ in
                defer {
                    dragging = nil
                    draft = nil
                    frozen = nil
                }
                guard let draft, let moving = model.layoutDevices.first(where: { $0.id == device.id }) else { return }
                let others = model.layoutDevices.filter { $0.id != device.id }.map(\.frame)
                let rect = moving.size.offsetBy(dx: draft.x, dy: draft.y)
                let snapped = LayoutMath.snap(rect, others: others, threshold: max(rect.width, rect.height) * 0.08)
                model.moveDevice(device.id, to: VPoint(snapped.minX - moving.size.minX, snapped.minY - moving.size.minY))
            }
    }
}

private struct DeviceTile: View {
    let device: LayoutDevice
    let scale: Double
    let isDragging: Bool
    let isolated: Bool

    var body: some View {
        let size = device.size
        ZStack(alignment: .topLeading) {
            ForEach(Array(device.displays.enumerated()), id: \.offset) { _, display in
                RoundedRectangle(cornerRadius: 4)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(stroke, lineWidth: isDragging ? 2 : 1))
                    .frame(width: max(8, display.width * scale), height: max(8, display.height * scale))
                    .offset(x: (display.minX - size.minX) * scale, y: (display.minY - size.minY) * scale)
            }
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(device.name).font(.caption).lineLimit(1)
                if device.nativePair {
                    Text("Universal Control").font(.caption2).foregroundStyle(.secondary)
                } else if isolated {
                    Text("Not touching another Mac").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(4)
            .frame(width: max(8, size.width * scale), height: max(8, size.height * scale))
        }
        .frame(width: max(8, size.width * scale), height: max(8, size.height * scale), alignment: .topLeading)
        .shadow(radius: isDragging ? 6 : 0)
    }

    private var icon: String {
        if device.nativePair { return "link" }
        return device.isLocal ? "laptopcomputer" : "desktopcomputer"
    }

    private var fill: Color {
        device.isLocal ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(device.nativePair ? 0.15 : 0.3)
    }

    private var stroke: Color {
        isDragging ? .accentColor : Color.primary.opacity(0.4)
    }
}

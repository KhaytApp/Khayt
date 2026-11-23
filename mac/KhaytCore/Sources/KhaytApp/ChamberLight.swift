import SwiftUI
import KhaytCore

/// The chamber light on a camera tile: "Light on" / "Light off", over the
/// picture, where a shop watching a dark chamber reaches for it. Figma
/// Qqxg4imtKVgC3TfNGcRGOk 181:285. Nothing is drawn until the printer has said
/// it has the light and what it is (`Camera.lights`).
struct ChamberLightButton: View {
    let machine: Machine
    let camera: Camera
    let shop: Shop

    var body: some View {
        if let light = camera.lights[machine.id] {
            let words = shop.words
            let (on, busy) = Self.reading(light)
            Button {
                Task { await camera.setLight(machine, on: !on, shop: shop) }
            } label: {
                Label(words.callIt(on ? "mac.light_button_on" : "mac.light_button_off"),
                      systemImage: on ? "lightbulb.fill" : "lightbulb")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || !shop.canMoveJobs || !shop.printerAllows("control"))
            .opacity(busy ? 0.5 : 1)
            .help(words.callIt("mac.light_chamber"))
        }
    }

    /// What the switch shows for a state, and whether it is held.
    static func reading(_ light: Camera.Light) -> (on: Bool, busy: Bool) {
        switch light {
        case .on: (true, false)
        case .off: (false, false)
        case .switching(let to): (to, true)
        case .failed(let was): (was, false)
        }
    }
}

/// The machine sheet's camera preview and chamber-light row. Figma 181:223,
/// states 181:247: on, off, switching (held until the printer says), could not
/// reach it (snaps back, says so), and offline (no switch, no guess).
struct CameraAndLight: View {
    let machine: Machine
    let shop: Shop
    @State private var keptAwake = false

    var body: some View {
        let words = shop.words
        let camera = shop.cameras
        VStack(alignment: .leading, spacing: 10) {
            if machine.hasCamera, machine.inService {
                CameraTile(frame: camera.frames[machine.id] ?? .none, webcam: machine.webcam,
                           height: 200, words: words)
                    .onAppear { camera.watch(machine, shop: shop) }
                    .onDisappear { camera.unwatch(machine.id) }
                if keptAwake {
                    Text(words.callIt("mac.cam_awake_note"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let light = camera.lights[machine.id] {
                let (on, busy) = ChamberLightButton.reading(light)
                HStack {
                    Text(words.callIt("mac.light_chamber"))
                    Spacer()
                    Text(words.callIt(busy ? (on ? "mac.light_turning_on" : "mac.light_turning_off")
                                           : (on ? "mac.light_on" : "mac.light_off")))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(get: { on }, set: { want in
                        Task { await camera.setLight(machine, on: want, shop: shop) }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(busy || !shop.canMoveJobs || !shop.printerAllows("control"))
                }
                if case .failed(let was) = light {
                    Text(words.callIt(was ? "mac.light_failed_on" : "mac.light_failed_off"))
                        .font(.callout).foregroundStyle(Khayt.late)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Khayt.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(words.callIt("mac.light_note"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: machine.id) {
            await camera.readLight(machine, shop: shop)
            if let engine = shop.engine, let rec = await U1Camera.record(machine, shop: shop) {
                keptAwake = (try? await engine.keepAwake(machine: rec.row)) != nil
            }
        }
    }
}

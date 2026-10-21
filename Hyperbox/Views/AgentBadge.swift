import SwiftUI

/// Shows in the toolbar while an agent is using the machine, so you know the pointer moving isn't you.
struct AgentBadge: ToolbarContent {
    let machine: Machine

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if machine.agentActive {
                Label("Agent", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                    .help("An AI agent is using this machine's screen, keyboard and mouse. Turn Agent Control off in the machine's settings to stop it.")
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// A soft edge of light around the screen while an agent uses it, visible in full screen too.
    func agentGlow(_ machine: Machine) -> some View {
        overlay {
            Rectangle()
                .strokeBorder(.tint.opacity(0.7), lineWidth: 3)
                .blur(radius: 3)
                .opacity(machine.agentActive ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: machine.agentActive)
                .allowsHitTesting(false)
        }
    }
}

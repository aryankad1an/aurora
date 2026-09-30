import SwiftUI

// MARK: - Liquid transitions
//
// Surfaces don't slide or pop into place; they condense as they grow and
// dissolve as they leave — the way a droplet forms, rather than the way a card
// is dealt. These are the shared shapes of that motion.
//
// One rule: nothing here blurs. An animated blur forces an offscreen render of
// the whole surface every frame, and these transitions run on chips inside list
// rows, on empty states and on glass — the system's own transitions scale, move
// and fade, and so do these.

/// Grows in from slightly small while fading in; shrinks and fades out.
struct LiquidMaterialize: Transition {
    var scale: CGFloat = 0.88
    var anchor: UnitPoint = .center
    /// Optional drift, for things that rise into place from an edge.
    var offset: CGSize = .zero

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : scale, anchor: anchor)
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(phase.isIdentity ? .zero : offset)
    }
}

extension Transition where Self == LiquidMaterialize {
    /// The default arrival for a surface.
    static var liquid: LiquidMaterialize { LiquidMaterialize() }

    /// A glass bar rising from the bottom edge.
    static var glassRise: LiquidMaterialize {
        LiquidMaterialize(scale: 0.94, anchor: .bottom, offset: CGSize(width: 0, height: 20))
    }

    /// A glass capsule appearing in place.
    static var glassPop: LiquidMaterialize {
        LiquidMaterialize(scale: 0.88)
    }
}

/// The splash leaving: it swells, softens and dissolves, so the app surfaces
/// through it rather than having it wiped off.
struct LiquidDissolve: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 1.14)
            .blur(radius: phase.isIdentity ? 0 : 24)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

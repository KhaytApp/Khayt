import SwiftUI

extension View {
    /// At least 44 x 44 pt to tap, Apple's minimum, without changing what is
    /// drawn: the frame sits OUTSIDE the control's own background, and the
    /// whole of it takes the tap (UI review Nov 11, F8).
    func tapTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

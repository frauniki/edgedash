import EdgeCore
import SwiftUI

public extension EnvironmentValues {
    @Entry var theme: Theme = BuiltinThemes.graphite
}

public extension ThemeColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

public extension Theme {
    var surfaceGradient: LinearGradient {
        LinearGradient(
            colors: [surfaceTop.color, surfaceBottom.color],
            startPoint: .top, endPoint: .bottom
        )
    }

    var strokeGradient: LinearGradient {
        LinearGradient(
            colors: [strokeTop.color, strokeBottom.color],
            startPoint: .top, endPoint: .bottom
        )
    }
}

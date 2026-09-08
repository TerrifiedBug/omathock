import QtQuick
import QtQuick.Shapes
import qs.Commons

// The thock mark, drawn as a vector so it takes the bar's foreground colour
// and sits at the same optical weight as the Nerd Font glyphs beside it.
//
// The two pieces are the upper-left bar and the lower-right corner of the
// wordmark's "T", split by its 45° slice. Coordinates are a 64-unit design
// box traced from the app icon in kamillobinski/thock (MIT); the Scale below
// maps that box onto whatever size the caller asks for.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property string upperPath: "M 8 1 L 48 1 L 28 23 L 0 23 L 0 9 A 8 8 0 0 1 8 1 Z"
  readonly property string lowerPath: "M 52 10 L 64 10 L 64 32 A 4 4 0 0 1 60 36 L 42 36 L 42 58 A 5 5 0 0 1 37 63 L 23 63 A 2 2 0 0 1 21 61 L 21 32 L 32 32 Z"

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  // Drawn at design size and scaled as an item: a layer or a Shape transform
  // would rasterise into the (small) item rect first and clip the mark away.
  Shape {
    width: 64
    height: 64
    transformOrigin: Item.TopLeft
    scale: root.width / 64
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      strokeWidth: 0

      PathSvg { path: root.upperPath }
    }

    ShapePath {
      fillColor: root.color
      strokeWidth: 0

      PathSvg { path: root.lowerPath }
    }
  }
}

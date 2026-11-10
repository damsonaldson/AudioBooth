#if canImport(GoogleCast) && !os(watchOS)
import GoogleCast
import SwiftUI

/// Pixel-perfect Google Cast icon drawn via SwiftUI Canvas using official Material Design vector paths.
struct ChromecastIcon: View {
  var isConnected: Bool = false

  var body: some View {
    Canvas { context, size in
      let s = min(size.width, size.height) / 24.0
      let offsetX = (size.width - 24.0 * s) / 2.0
      let offsetY = (size.height - 24.0 * s) / 2.0

      context.translateBy(x: offsetX, y: offsetY)

      var path = Path()

      // Wave 1: bottom-left dot/quarter-circle
      path.move(to: CGPoint(x: 1 * s, y: 18 * s))
      path.addLine(to: CGPoint(x: 1 * s, y: 21 * s))
      path.addLine(to: CGPoint(x: 4 * s, y: 21 * s))
      path.addCurve(
        to: CGPoint(x: 1 * s, y: 18 * s),
        control1: CGPoint(x: 4 * s, y: 19.34 * s),
        control2: CGPoint(x: 2.66 * s, y: 18 * s)
      )
      path.closeSubpath()

      // Wave 2: middle arc
      path.move(to: CGPoint(x: 1 * s, y: 14 * s))
      path.addLine(to: CGPoint(x: 1 * s, y: 16 * s))
      path.addCurve(
        to: CGPoint(x: 6 * s, y: 21 * s),
        control1: CGPoint(x: 3.76 * s, y: 16 * s),
        control2: CGPoint(x: 6 * s, y: 18.24 * s)
      )
      path.addLine(to: CGPoint(x: 8 * s, y: 21 * s))
      path.addCurve(
        to: CGPoint(x: 1 * s, y: 14 * s),
        control1: CGPoint(x: 8 * s, y: 17.13 * s),
        control2: CGPoint(x: 4.87 * s, y: 14 * s)
      )
      path.closeSubpath()

      // Wave 3: outer arc
      path.move(to: CGPoint(x: 1 * s, y: 10 * s))
      path.addLine(to: CGPoint(x: 1 * s, y: 12 * s))
      path.addCurve(
        to: CGPoint(x: 10 * s, y: 21 * s),
        control1: CGPoint(x: 5.97 * s, y: 12 * s),
        control2: CGPoint(x: 10 * s, y: 16.03 * s)
      )
      path.addLine(to: CGPoint(x: 12 * s, y: 21 * s))
      path.addCurve(
        to: CGPoint(x: 1 * s, y: 10 * s),
        control1: CGPoint(x: 12 * s, y: 14.92 * s),
        control2: CGPoint(x: 7.07 * s, y: 10 * s)
      )
      path.closeSubpath()

      // Screen outline
      path.move(to: CGPoint(x: 21 * s, y: 3 * s))
      path.addLine(to: CGPoint(x: 3 * s, y: 3 * s))
      path.addCurve(
        to: CGPoint(x: 1 * s, y: 5 * s),
        control1: CGPoint(x: 1.9 * s, y: 3 * s),
        control2: CGPoint(x: 1 * s, y: 3.9 * s)
      )
      path.addLine(to: CGPoint(x: 1 * s, y: 8 * s))
      path.addLine(to: CGPoint(x: 3 * s, y: 8 * s))
      path.addLine(to: CGPoint(x: 3 * s, y: 5 * s))
      path.addLine(to: CGPoint(x: 21 * s, y: 5 * s))
      path.addLine(to: CGPoint(x: 21 * s, y: 19 * s))
      path.addLine(to: CGPoint(x: 14 * s, y: 19 * s))
      path.addLine(to: CGPoint(x: 14 * s, y: 21 * s))
      path.addLine(to: CGPoint(x: 21 * s, y: 21 * s))
      path.addCurve(
        to: CGPoint(x: 23 * s, y: 19 * s),
        control1: CGPoint(x: 22.1 * s, y: 21 * s),
        control2: CGPoint(x: 23 * s, y: 20.1 * s)
      )
      path.addLine(to: CGPoint(x: 23 * s, y: 5 * s))
      path.addCurve(
        to: CGPoint(x: 21 * s, y: 3 * s),
        control1: CGPoint(x: 23 * s, y: 3.9 * s),
        control2: CGPoint(x: 22.1 * s, y: 3 * s)
      )
      path.closeSubpath()

      if isConnected {
        // Fill inner screen when connected
        let innerRect = CGRect(x: 5 * s, y: 7 * s, width: 14 * s, height: 10 * s)
        path.addRoundedRect(in: innerRect, cornerSize: CGSize(width: 1 * s, height: 1 * s))
      }

      context.fill(path, with: .foreground)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct CastButton: View {
  @ObservedObject private var castManager = CastManager.shared

  var body: some View {
    Menu {
      if castManager.isConnected {
        Section(castManager.deviceName ?? "Chromecast") {
          Button(role: .destructive, action: {
            castManager.disconnect()
          }) {
            Label("Disconnect", systemImage: "xmark.circle")
          }
        }
      } else if castManager.discoveredDevices.isEmpty {
        Text("No Cast devices found")
        Button(action: {
          GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
          GCKCastContext.sharedInstance().presentCastDialog()
        }) {
          Label("Search for Devices", systemImage: "arrow.clockwise")
        }
        Button(action: {
          GCKCastContext.sharedInstance().presentCastDialog()
        }) {
          Label("Cast Dialog", systemImage: "tv")
        }
      } else {
        Section("Cast to") {
          ForEach(castManager.discoveredDevices, id: \.deviceID) { device in
            Button(action: {
              castManager.connect(to: device)
            }) {
              Label(device.friendlyName ?? "Chromecast", systemImage: "tv")
            }
          }
        }
        Button(action: {
          GCKCastContext.sharedInstance().presentCastDialog()
        }) {
          Label("Cast Dialog", systemImage: "ellipsis")
        }
      }
    } label: {
      ChromecastIcon(isConnected: castManager.isConnected)
        .foregroundStyle(castManager.isConnected ? Color.accentColor : Color.white)
        .frame(width: 22, height: 22)
        .frame(width: 36, height: 36)
    }
    .onAppear {
      castManager.refreshDiscoveredDevices()
    }
  }
}
#endif

#if canImport(GoogleCast) && !os(watchOS)
import GoogleCast
import SwiftUI

struct CastButton: View {
  @ObservedObject private var castManager = CastManager.shared

  var body: some View {
    Button(action: {
      GCKCastContext.sharedInstance().presentCastDialog()
    }) {
      Image(systemName: castManager.isConnected ? "tv.and.mediabox.fill" : "tv.and.mediabox")
        .font(.system(size: 19))
        .foregroundStyle(castManager.isConnected ? Color.accentColor : Color.white)
        .frame(width: 36, height: 36)
    }
  }
}
#endif

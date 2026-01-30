import ExpoModulesCore
import HaishinKit
import AVFoundation

public class ExpoSettingsView: ExpoView {
  public static weak var current: ExpoSettingsView?

  private let hkView: MTHKView = {
    let view = MTHKView(frame: .zero)
    view.videoGravity = .resizeAspectFill
    return view
  }()

  // Guarda stream para reattach se a view recriar/layout mudar
  private weak var attachedStream: RTMPStream?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    addSubview(hkView)
    ExpoSettingsView.current = self
    print("[ExpoSettingsView] initialized")
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    hkView.frame = bounds
  }

  // agora aceita nil
  public func attachStream(_ stream: RTMPStream?) {
    attachedStream = stream
    hkView.attachStream(stream) // normalmente aceita nil
  }

  deinit {
    if ExpoSettingsView.current === self {
      ExpoSettingsView.current = nil
    }
  }
}
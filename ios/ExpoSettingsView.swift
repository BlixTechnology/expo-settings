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

  public func attachStream(_ stream: RTMPStream) {
    hkView.attachStream(stream)
  }

  deinit {
    if ExpoSettingsView.current === self {
      ExpoSettingsView.current = nil
    }
  }
}
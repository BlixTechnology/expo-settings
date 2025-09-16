import ExpoModulesCore
import HaishinKit
import AVFoundation

public class ExpoSettingsView: ExpoView {
    
    public static weak var current: ExpoSettingsView?
    
    // A view de preview do HaishinKit
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
        print("[ExpoSettingsView] View initialized and set as current")
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        hkView.frame = bounds
        print("[ExpoSettingsView] Layout updated, frame: \(bounds)")
    }

    /// Na versão 2.x do HaishinKit, a MTHKView é adicionada como um output do MediaMixer ou RTMPStream.
    /// A função attachStream direta na view não é mais utilizada.
    // public func attachStream(_ stream: RTMPStream) {
    //     print("[ExpoSettingsView] Attaching stream to view")
    //     hkView.attachStream(stream)
    // }
    
    deinit {
        print("[ExpoSettingsView] View being deinitialized")
        if ExpoSettingsView.current === self {
            ExpoSettingsView.current = nil
        }
    }
}
import ExpoModulesCore
import HaishinKit
import AVFoundation
import VideoToolbox

public class ExpoSettingsModule: Module {
  private var rtmpConnection: RTMPConnection?
  private var rtmpStream: RTMPStream?
  private var currentStreamStatus: String = "stopped"

  public func definition() -> ModuleDefinition {
    Name("ExpoSettings")

    View(ExpoSettingsView.self) {}

    Events("onStreamStatus")

    Function("getStreamStatus") {
      return self.currentStreamStatus
    }

    Function("initializePreview") { () -> Void in
      self.setStatus("previewInitializing")

      self.configureAudioSession()

      let connection = RTMPConnection()
      self.rtmpConnection = connection

      let stream = RTMPStream(connection: connection)
      self.rtmpStream = stream

      self.configureStream(stream)
      self.attachAudioIfAvailable(stream)
      self.attachFrontCamera(stream)
      self.attachPreviewIfAvailable(stream)

      self.setStatus("previewReady")
    }

    Function("publishStream") { (url: String, streamKey: String) -> Void in
      self.setStatus("connecting")
      print("[ExpoSettings] Publishing to: \(url) key: \(streamKey)")

      // Se não existe stream/connection, cria e aplica TODA a config
      if self.rtmpConnection == nil || self.rtmpStream == nil {
        let connection = RTMPConnection()
        self.rtmpConnection = connection

        let stream = RTMPStream(connection: connection)
        self.rtmpStream = stream

        self.configureStream(stream)
        self.attachAudioIfAvailable(stream)
        self.attachFrontCamera(stream)
        self.attachPreviewIfAvailable(stream)
      }

      self.rtmpConnection?.connect(url)
      self.setStatus("connected")

      self.setStatus("publishing")
      self.rtmpStream?.publish(streamKey)

      self.setStatus("started")
    }

    Function("stopStream") { () -> Void in
      print("[ExpoSettings] stopStream called")

      if let stream = self.rtmpStream {
        stream.close()
        stream.attachCamera(nil)
        stream.attachAudio(nil)
      }

      if let connection = self.rtmpConnection {
        connection.close()
      }

      self.rtmpStream = nil
      self.rtmpConnection = nil

      self.setStatus("stopped")
    }
  }

  // MARK: - Internals

  private func setStatus(_ status: String) {
    self.currentStreamStatus = status
    sendEvent("onStreamStatus", ["status": status])
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try session.setActive(true)
    } catch {
      print("[ExpoSettings] AVAudioSession error:", error)
    }
  }

  private func configureStream(_ stream: RTMPStream) {
    print("[ExpoSettings] Configuring stream...")

    // 1) Captura previsível (16:9)
    stream.sessionPreset = .hd1280x720
    stream.frameRate = 30

    // 2) Orientação no nível do stream (governa pipeline)
    stream.videoOrientation = .portrait

    // 3) Áudio
    var audioSettings = AudioCodecSettings()
    audioSettings.bitRate = 128 * 1000
    stream.audioSettings = audioSettings

    // 4) Vídeo (9:16). Use 720x1280 para estabilidade
    let videoSettings = VideoCodecSettings(
      videoSize: .init(width: 720, height: 1280),
      bitRate: 4_000 * 1000,
      profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
      scalingMode: .trim, // sem distorção (corta). Alternativa: .letterbox (barras)
      bitRateMode: .average,
      maxKeyFrameIntervalDuration: 2,
      allowFrameReordering: nil,
      isHardwareEncoderEnabled: true
    )
    stream.videoSettings = videoSettings

    print("[ExpoSettings] Stream configured preset=\(stream.sessionPreset.rawValue) fps=\(stream.frameRate)")
    print("[ExpoSettings] Target=\(Int(videoSettings.videoSize.width))x\(Int(videoSettings.videoSize.height)) orientation=portrait")
  }

  private func attachAudioIfAvailable(_ stream: RTMPStream) {
    if let audioDevice = AVCaptureDevice.default(for: .audio) {
      print("[ExpoSettings] Attaching audio")
      stream.attachAudio(audioDevice)
    } else {
      print("[ExpoSettings] No audio device found")
    }
  }

  private func attachFrontCamera(_ stream: RTMPStream) {
    guard let camera = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .front
    ) else {
      print("[ExpoSettings] No front camera found")
      return
    }

    print("[ExpoSettings] Attaching front camera")

    stream.attachCamera(camera) { videoUnit, error in
      guard let unit = videoUnit else {
        print("[ExpoSettings] attachCamera error:", error?.localizedDescription ?? "unknown")
        return
      }

      unit.isVideoMirrored = true
      unit.videoOrientation = .portrait   // <-- GARANTA que está .portrait (não .po)
      unit.preferredVideoStabilizationMode = .standard
      unit.colorFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
  }

  private func attachPreviewIfAvailable(_ stream: RTMPStream) {
    DispatchQueue.main.async {
      if let preview = ExpoSettingsView.current {
        print("[ExpoSettings] Attaching stream to preview")
        preview.attachStream(stream)
      } else {
        print("[ExpoSettings] Preview not available yet")
      }
    }
  }
}
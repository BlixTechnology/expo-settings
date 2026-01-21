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

    // View component (preview)
    View(ExpoSettingsView.self) {
      // sem props
    }

    Events("onStreamStatus")

    Function("getStreamStatus") {
      return self.currentStreamStatus
    }

    Function("initializePreview") { () -> Void in
      Task {
        self.setStatus("previewInitializing")

        // 0) Configura AVAudioSession
        self.configureAudioSession()

        // 1) Cria connection + stream
        let connection = RTMPConnection()
        self.rtmpConnection = connection

        let stream = RTMPStream(connection: connection)
        self.rtmpStream = stream

        // 2) Configura stream (tudo que influencia proporção/encode)
        self.configureStream(stream)

        // 3) Attach áudio
        self.attachAudioIfAvailable(stream)

        // 4) Attach câmera frontal (portrait + mirror)
        await self.attachFrontCamera(stream)

        // 5) Attach preview (MainActor)
        await self.attachPreviewIfAvailable(stream)

        self.setStatus("previewReady")
      }
    }

    Function("publishStream") { (url: String, streamKey: String) -> Void in
      Task {
        print("[ExpoSettings] Publishing stream to URL: \(url) with key: \(streamKey)")
        self.setStatus("connecting")

        // Caso não tenha initializePreview, cria do zero com config completa
        if self.rtmpConnection == nil || self.rtmpStream == nil {
          print("[ExpoSettings] WARNING: Connection or stream not initialized. Creating new ones.")

          let connection = RTMPConnection()
          self.rtmpConnection = connection

          let stream = RTMPStream(connection: connection)
          self.rtmpStream = stream

          self.configureStream(stream)
          self.attachAudioIfAvailable(stream)
          await self.attachFrontCamera(stream)
          await self.attachPreviewIfAvailable(stream)
        }

        // Conecta
        self.rtmpConnection?.connect(url)
        self.setStatus("connected")

        // Publica
        self.setStatus("publishing")
        self.rtmpStream?.publish(streamKey)
        print("[ExpoSettings] Stream published successfully")

        self.setStatus("started")
      }
    }

    Function("stopStream") { () -> Void in
      Task {
        print("[ExpoSettings] stopStream called")

        if let stream = self.rtmpStream {
          print("[ExpoSettings] Stopping stream publication")
          stream.close()

          // Libera recursos
          stream.attachCamera(nil)
          stream.attachAudio(nil)
        }

        if let connection = self.rtmpConnection {
          print("[ExpoSettings] Closing RTMP connection")
          connection.close()
        }

        self.rtmpStream = nil
        self.rtmpConnection = nil

        print("[ExpoSettings] Stream and connection closed and resources released")
        self.setStatus("stopped")
      }
    }
  }

  // MARK: - Helpers

  private func setStatus(_ status: String) {
    self.currentStreamStatus = status
    sendEvent("onStreamStatus", ["status": status])
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord,
                              mode: .default,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      print("[ExpoSettings] AVAudioSession error:", error)
    }
  }

  /// Configuração centralizada do stream (evita mismatch entre preview/publish).
  private func configureStream(_ stream: RTMPStream) {
    print("[ExpoSettings] Configuring stream...")

    // IMPORTANTE: preset primeiro, depois FPS (evita fallback estranho)
    stream.sessionPreset = .hd1280x720
    stream.frameRate = 30

    // Orientação no nível do stream (governança do pipeline)
    stream.videoOrientation = .portrait

    // Sugestão para estabilidade de scaling/mix
    stream.videoMixerSettings.mode = .offscreen

    // Opcional: deixa o capture session gerenciar áudio automaticamente
    stream.configuration { captureSession in
      captureSession.automaticallyConfiguresApplicationAudioSession = true
    }

    // Áudio
    var audioSettings = AudioCodecSettings()
    audioSettings.bitRate = 128 * 1000
    stream.audioSettings = audioSettings

    // Vídeo (vertical 9:16)
    // 720x1280 é um “sweet spot” pra compatibilidade e estabilidade
    let videoSettings = VideoCodecSettings(
      videoSize: .init(width: 720, height: 1280),
      bitRate: 4_000 * 1000,
      profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
      scalingMode: .trim, // sem distorção (corta excesso). Alternativa: .letterbox (barras)
      bitRateMode: .average,
      maxKeyFrameIntervalDuration: 2,
      allowFrameReordering: nil,
      isHardwareEncoderEnabled: true
    )
    stream.videoSettings = videoSettings

    print("[ExpoSettings] Stream configured: preset=\(stream.sessionPreset.rawValue), fps=\(stream.frameRate), orientation=\(stream.videoOrientation.rawValue)")
    print("[ExpoSettings] Encoder target: \(Int(videoSettings.videoSize.width))x\(Int(videoSettings.videoSize.height)) scaling=\(videoSettings.scalingMode.rawValue)")
  }

  private func attachAudioIfAvailable(_ stream: RTMPStream) {
    if let audioDevice = AVCaptureDevice.default(for: .audio) {
      print("[ExpoSettings] Attaching audio device")
      stream.attachAudio(audioDevice)
    } else {
      print("[ExpoSettings] No audio device found")
    }
  }

  private func attachFrontCamera(_ stream: RTMPStream) async {
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                               for: .video,
                                               position: .front) else {
      print("[ExpoSettings] No front camera device found")
      return
    }

    print("[ExpoSettings] Attaching front camera device")

    stream.attachCamera(camera) { videoUnit, error in
      guard let unit = videoUnit else {
        print("[ExpoSettings] attachCamera error:", error?.localizedDescription ?? "unknown")
        return
      }

      unit.isVideoMirrored = true
      unit.videoOrientation = .po
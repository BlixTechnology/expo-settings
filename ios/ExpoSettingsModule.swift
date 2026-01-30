import ExpoModulesCore
import HaishinKit
import AVFoundation
import VideoToolbox
import Logboard

// MARK: - RTMP Event Observer

final class RTMPEventObserver: NSObject {
  var onStatus: ((String, String, String) -> Void)?
  var onError: ((String) -> Void)?

  @objc func rtmpStatusHandler(_ notification: Notification) {
    let e: Event = Event.from(notification)
    guard let data = e.data as? [String: Any] else { return }
    let code = data["code"] as? String ?? ""
    let level = data["level"] as? String ?? ""
    let desc = data["description"] as? String ?? ""
    onStatus?(code, level, desc)
  }

  @objc func rtmpErrorHandler(_ notification: Notification) {
    let e: Event = Event.from(notification)
    onError?("ioError: \(e)")
  }
}

// MARK: - Module

public class ExpoSettingsModule: Module {
  private var rtmpConnection: RTMPConnection?
  private var rtmpStream: RTMPStream?
  private var currentStreamStatus: String = "stopped"
  private let rtmpObserver = RTMPEventObserver()

  private var pendingPublish: (url: String, streamKey: String)?
  private var statsTimer: Timer?

  // Timing/debug
  private var previewInitTime: Date?
  private var publishRequestTime: Date?
  private var firstDataSentTime: Date?
  private var stopRequestTime: Date?
  private var lastDataSentTime: Date?

  // Stream config
  private let TARGET_ASPECT_RATIO: CGFloat = 9.0 / 16.0
  private var calculatedVideoWidth: Int = 720
  private var calculatedVideoHeight: Int = 1280
  private var configuredBitrate: Int = 2_500_000
  private var configuredFrameRate: Float64 = 30

  // Monitor cancellation
  private var dataMonitorToken: UUID?
  private var stopFlushToken: UUID?

  public func definition() -> ModuleDefinition {
    Name("ExpoSettings")

    // Registra o view component para o admin se enxergar na live

    View(ExpoSettingsView.self) {
      // não precisa colocar nada aqui se você não tiver Props
    }

    Events("onStreamStatus", "onStreamStats", "onStreamTiming")

    Function("getStreamStatus") {
      return self.currentStreamStatus
    }

    Function("getStreamInfo") { () -> [String: Any] in
      let w = self.calculatedVideoWidth
      let h = self.calculatedVideoHeight
      let ar = (h == 0) ? 0.0 : (Double(w) / Double(h))
      return [
        "videoWidth": w,
        "videoHeight": h,
        "aspectRatio": String(format: "%.4f", ar),
        "bitrate": self.configuredBitrate,
        "frameRate": self.configuredFrameRate
      ]
    }

    Function("getDeviceDimensions") { () -> [String: Any] in
      let screen = UIScreen.main.bounds
      let scale = UIScreen.main.scale
      return [
        "screenWidth": Int(screen.width),
        "screenHeight": Int(screen.height),
        "scale": scale,
        "pixelWidth": Int(screen.width * scale),
        "pixelHeight": Int(screen.height * scale),
        "streamWidth": self.calculatedVideoWidth,
        "streamHeight": self.calculatedVideoHeight,
        "aspectRatio": String(format: "%.4f", Double(self.calculatedVideoWidth) / Double(max(self.calculatedVideoHeight, 1)))
      ]
    }

    Function("getStreamTiming") { () -> [String: Any] in
      var result: [String: Any] = [:]
      let fmt = ISO8601DateFormatter()

      if let t = self.previewInitTime { result["previewInitTime"] = fmt.string(from: t) }
      if let t = self.publishRequestTime { result["publishRequestTime"] = fmt.string(from: t) }
      if let t = self.firstDataSentTime { result["firstDataSentTime"] = fmt.string(from: t) }
      if let t = self.stopRequestTime { result["stopRequestTime"] = fmt.string(from: t) }
      if let t = self.lastDataSentTime { result["lastDataSentTime"] = fmt.string(from: t) }

      if let publish = self.publishRequestTime, let first = self.firstDataSentTime {
        result["startDelayMs"] = Int(first.timeIntervalSince(publish) * 1000)
      }

      if let stop = self.stopRequestTime, let last = self.lastDataSentTime {
        // Positive means stop happened after last data timestamp
        result["timeSinceLastDataMs"] = Int(stop.timeIntervalSince(last) * 1000)
      }

      return result
    }

    Function("initializePreview") { () -> Void in
      DispatchQueue.main.async { self.initializePreview() }
    }

    Function("publishStream") { (url: String, streamKey: String) -> Void in
      DispatchQueue.main.async { self.publishStream(url: url, streamKey: streamKey) }
    }

    Function("stopStream") { () -> Void in
      DispatchQueue.main.async { self.stopStream() }
    }
  }

  // MARK: - Helpers

  private func setStatus(_ s: String) {
    guard currentStreamStatus != s else { return }
    currentStreamStatus = s
    sendEvent("onStreamStatus", [
      "status": s,
      "timestamp": ISO8601DateFormatter().string(from: Date())
    ])
  }

  private func sanitizeRTMPUrl(_ url: String) -> String {
    var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while u.hasSuffix("/") { u.removeLast() }
    return u
  }

  private func calculateStreamDimensions() -> (width: Int, height: Int) {
    let width = 720
    let height = 1280

    let aspectRatio = CGFloat(width) / CGFloat(height)
    let expected = TARGET_ASPECT_RATIO

    assert(abs(aspectRatio - expected) < 0.001, "Aspect ratio mismatch!")

    print("[ExpoSettings] 📐 Stream dimensions: \(width)x\(height)")
    print("[ExpoSettings] 📐 Aspect ratio: \(String(format: "%.4f", aspectRatio)) expected \(String(format: "%.4f", expected))")
    return (width, height)
  }

  // MARK: - Permissions

  private func requestAVPermissions(completion: @escaping (Bool) -> Void) {
    let group = DispatchGroup()
    var camOK = false
    var micOK = false

    group.enter()
    AVCaptureDevice.requestAccess(for: .video) { granted in
      camOK = granted
      group.leave()
    }

    group.enter()
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      micOK = granted
      group.leave()
    }

    group.notify(queue: .main) {
      print("[ExpoSettings] camera permission \(camOK)")
      print("[ExpoSettings] mic permission \(micOK)")
      completion(camOK && micOK)
    }
  }

  // MARK: - Preview init

  private func initializePreview() {
    previewInitTime = Date()
    LBLogger.with("com.haishinkit.HaishinKit").level = .trace

    print("[ExpoSettings] ⏱️ initializePreview at \(ISO8601DateFormatter().string(from: previewInitTime!))")
    setStatus("previewInitializing")

    requestAVPermissions { [weak self] ok in
      guard let self else { return }
      guard ok else {
        print("[ExpoSettings] ❌ Missing camera/mic permissions")
        self.setStatus("error")
        return
      }

      // Audio session
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        print("[ExpoSettings] ✅ AudioSession OK")
      } catch {
        print("[ExpoSettings] ❌ AudioSession error: \(error)")
      }

      let connection = RTMPConnection()
      self.rtmpConnection = connection

      let stream = RTMPStream(connection: connection)

      // Attach listeners
      connection.addEventListener(.rtmpStatus,
                                 selector: #selector(RTMPEventObserver.rtmpStatusHandler(_:)),
                                 observer: self.rtmpObserver)
      connection.addEventListener(.ioError,
                                 selector: #selector(RTMPEventObserver.rtmpErrorHandler(_:)),
                                 observer: self.rtmpObserver)

      stream.addEventListener(.rtmpStatus,
                              selector: #selector(RTMPEventObserver.rtmpStatusHandler(_:)),
                              observer: self.rtmpObserver)
      stream.addEventListener(.ioError,
                              selector: #selector(RTMPEventObserver.rtmpErrorHandler(_:)),
                              observer: self.rtmpObserver)

      self.rtmpStream = stream

      self.rtmpObserver.onStatus = { [weak self] code, level, desc in
        self?.handleRTMPStatus(code: code, level: level, desc: desc)
      }
      self.rtmpObserver.onError = { [weak self] msg in
        print("[ExpoSettings] ❌ \(msg)")
        self?.setStatus("error")
      }

      // Dimensions
      let dimensions = self.calculateStreamDimensions()
      self.calculatedVideoWidth = dimensions.width
      self.calculatedVideoHeight = dimensions.height

      // Video settings
      self.configuredBitrate = 2_500_000
      self.configuredFrameRate = 30

        let videoSettings = VideoCodecSettings(
        videoSize: CGSize(width: dimensions.width, height: dimensions.height),
        bitRate: self.configuredBitrate,
        profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
        scalingMode: .trim,
        bitRateMode: .average,
        maxKeyFrameIntervalDuration: 1, // GOP 1s
        allowFrameReordering: nil,
        isHardwareEncoderEnabled: true
      )
      stream.videoSettings = videoSettings
      stream.frameRate = self.configuredFrameRate

      print("[ExpoSettings] 📐 VideoSettings videoSize=\(stream.videoSettings.videoSize) bitrate=\(stream.videoSettings.bitRate) GOP=\(stream.videoSettings.maxKeyFrameIntervalDuration) fps=\(stream.frameRate)")

      // Audio settings
      var audioSettings = AudioCodecSettings()
      audioSettings.bitRate = 128_000
      stream.audioSettings = audioSettings
      print("[ExpoSettings] 🔊 Audio bitRate: 128000")

      // Devices
      guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
        print("[ExpoSettings] ❌ No front camera")
        self.setStatus("error")
        return
      }
      guard let microphone = AVCaptureDevice.default(for: .audio) else {
        print("[ExpoSettings] ❌ No microphone")
        self.setStatus("error")
        return
      }

      // Attach camera (portrait, mirrored)
      stream.attachCamera(camera) { videoUnit, error in
        if let error = error {
          print("[ExpoSettings] ❌ Camera ERROR: \(error)")
        } else {
          videoUnit?.isVideoMirrored = true
          videoUnit?.videoOrientation = .portrait
          print("[ExpoSettings] ✅ Camera attached (portrait, mirrored)")
        }
      }

      stream.attachAudio(microphone) { _, error in
        if let error = error {
          print("[ExpoSettings] ❌ Audio ERROR: \(error.localizedDescription)")
        } else {
          print("[ExpoSettings] ✅ Audio attached")
        }
      }

      // Attach preview
      if let preview = ExpoSettingsView.current {
        preview.attachStream(stream) // requires RTMPStream? in view to allow nil later
        print("[ExpoSettings] ✅ Preview attached")
      }

      // Wait for encoder warm-up
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
        guard let self, let s = self.rtmpStream else { return }
        print("[ExpoSettings] 🔍 Warm verify videoSize=\(s.videoSettings.videoSize) fps=\(s.frameRate)")
        self.setStatus("previewReady")
        print("[ExpoSettings] ✅ Preview READY")
      }
    }
  }

  // MARK: - Publish

  private func publishStream(url: String, streamKey: String) {
    publishRequestTime = Date()
    firstDataSentTime = nil
    lastDataSentTime = nil
    stopRequestTime = nil

    // reset monitors
    dataMonitorToken = UUID()

    let cleanUrl = sanitizeRTMPUrl(url)
    print("[ExpoSettings] ⏱️ publishStream at \(ISO8601DateFormatter().string(from: publishRequestTime!))")
    print("[ExpoSettings]    URL: \(cleanUrl)")
    print("[ExpoSettings]    Key: \(streamKey)")

    guard let connection = rtmpConnection, let stream = rtmpStream else {
      print("[ExpoSettings] ❌ No connection/stream")
      setStatus("error")
      return
    }

    print("[ExpoSettings] 🔍 Pre-publish videoSize=\(stream.videoSettings.videoSize)")

    pendingPublish = (cleanUrl, streamKey)
    setStatus("connecting")
    connection.connect(cleanUrl)
  }

  // MARK: - RTMP status

  private func handleRTMPStatus(code: String, level: String, desc: String) {
    let now = Date()
    print("[ExpoSettings] ⏱️ RTMP status \(code) at \(ISO8601DateFormatter().string(from: now))")

    guard let stream = rtmpStream else { return }

    switch code {
    case "NetConnection.Connect.Success":
      setStatus("connected")
      if let p = pendingPublish {
        pendingPublish = nil
        setStatus("publishing")
        print("[ExpoSettings] 📤 Publishing...")
        stream.publish(p.streamKey, type: .live)

        // Start monitoring for real media egress
        monitorForRealOutboundMedia()
      }

    case "NetStream.Publish.Start":
      // IMPORTANT:
      // Do NOT setStatus("started") here anymore.
      // This event means publish handshake started, not necessarily that DVR/RTMP has real media yet.
      print("[ExpoSettings] ✅ Publish.Start received (waiting for data confirmation...)")

    case "NetStream.Publish.BadName",
         "NetStream.Publish.Rejected",
         "NetConnection.Connect.Failed":
      stopStatsTimer()
      setStatus("error")

    case "NetConnection.Connect.Closed":
      stopStatsTimer()
      setStatus("stopped")

    default:
      break
    }
  }

  // MARK: - Start confirmation (Fix #1)

  private func monitorForRealOutboundMedia() {
    guard let connection = rtmpConnection, let stream = rtmpStream else { return }
    let token = dataMonitorToken ?? UUID()
    dataMonitorToken = token

    var checks = 0
    let maxChecks = 200          // 20s (200 x 100ms)
    let interval: TimeInterval = 0.1

    // Require a few consecutive "good" checks to avoid flapping
    var goodStreak = 0
    let neededGoodStreak = 4     // 400ms stable

    func tick() {
      // cancelled?
      guard self.dataMonitorToken == token else { return }

      checks += 1

      let bytesOut = connection.currentBytesOutPerSecond // Int32
      let fps = stream.currentFPS

      // Track last data time if any egress
      if bytesOut > 0 && fps > 0 {
        self.lastDataSentTime = Date()
      }

      if bytesOut > 0 && fps > 0 {
        goodStreak += 1
      } else {
        goodStreak = 0
      }

      // Confirm start ONLY when stable outbound is observed
      if goodStreak >= neededGoodStreak {
        if self.firstDataSentTime == nil {
          self.firstDataSentTime = Date()
        }

        let delayMs = self.publishRequestTime.flatMap { pub in
          self.firstDataSentTime.map { Int($0.timeIntervalSince(pub) * 1000) }
        } ?? -1

        print("[ExpoSettings] ✅ Data confirmed (bytesOut=\(bytesOut), fps=\(fps)) after \(delayMs)ms")

        // Emit timing events (send both names to match any JS)
        self.sendEvent("onStreamTiming", [
          "event": "dataConfirmed",
          "delayMs": delayMs,
          "timestamp": ISO8601DateFormatter().string(from: self.firstDataSentTime ?? Date())
        ])
        self.sendEvent("onStreamTiming", [
          "event": "firstDataSent",
          "delayMs": delayMs,
          "timestamp": ISO8601DateFormatter().string(from: self.firstDataSentTime ?? Date())
        ])

        self.setStatus("started")
        self.startStatsTimer()
        return
      }

      // Timeout
      if checks >= maxChecks {
        print("[ExpoSettings] ⚠️ Start confirmation timeout (still no stable outbound media). Keeping status=\(self.currentStreamStatus)")
        // Keep status as "publishing" or whatever it currently is; do not force started.
        return
      }

      // Keep checking while in publishing/connected state
      if self.currentStreamStatus == "publishing" || self.currentStreamStatus == "connected" || self.currentStreamStatus == "connecting" {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { tick() }
      }
    }

    tick()
  }

  // MARK: - Stats

  private func startStatsTimer() {
    stopStatsTimer()
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self,
            let c = self.rtmpConnection,
            let s = self.rtmpStream else { return }

      let fps = s.currentFPS
      let bps = c.currentBytesOutPerSecond * 8

      if bps > 0 {
        self.lastDataSentTime = Date()
      }

      self.sendEvent("onStreamStats", [
        "fps": fps,
        "bps": bps,
        "timestamp": ISO8601DateFormatter().string(from: Date())
      ])
    }
  }

  private func stopStatsTimer() {
    statsTimer?.invalidate()
    statsTimer = nil
  }

  // MARK: - Stop (Fix #2)

  private func stopStream() {
    stopRequestTime = Date()
    print("[ExpoSettings] ⏱️ stopStream at \(ISO8601DateFormatter().string(from: stopRequestTime!))")

    // cancel start confirmation monitor
    dataMonitorToken = UUID()

    stopStatsTimer()

    guard let stream = rtmpStream, let connection = rtmpConnection else {
      print("[ExpoSettings] No active stream to stop")
      setStatus("stopped")
      return
    }

    setStatus("stopping")

    // Stop capturing new frames but keep connection open for flush
    print("[ExpoSettings] 📤 Stop capture (keep RTMP open for flush)")
    stream.attachCamera(nil) { _, _ in }
    stream.attachAudio(nil) { _, _ in }

    // Adaptive flush: wait until outbound bytes are ~0 for a stable window, OR max time reached
    stopFlushToken = UUID()
    let token = stopFlushToken!

    let interval: TimeInterval = 0.2
    let maxFlushSeconds: TimeInterval = 12.0
    let stableZeroNeeded: Int = 6     // 6 * 0.2s = 1.2s stable

    var elapsed: TimeInterval = 0
    var stableZeroCount = 0

    func flushTick() {
      guard self.stopFlushToken == token else { return }

      let bytesOut = connection.currentBytesOutPerSecond
      let now = Date()

      // if still sending, update lastDataSentTime
      if bytesOut > 0 {
        self.lastDataSentTime = now
        stableZeroCount = 0
      } else {
        stableZeroCount += 1
      }

      elapsed += interval

      // Condition to proceed: stable no outbound OR max wait
      if stableZeroCount >= stableZeroNeeded || elapsed >= maxFlushSeconds {
        print("[ExpoSettings] ✅ Flush condition met (stableZeroCount=\(stableZeroCount), elapsed=\(String(format: "%.1f", elapsed))s). Closing stream...")

        // Close stream then connection
        self.rtmpStream?.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          guard let self else { return }
          self.rtmpConnection?.close()

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }

            // Detach preview if your view supports optional
            if let preview = ExpoSettingsView.current {
              preview.attachStream(nil)
            }

            let finalTime = Date()
            let totalMs = self.stopRequestTime.map { Int(finalTime.timeIntervalSince($0) * 1000) } ?? -1

            self.sendEvent("onStreamTiming", [
              "event": "shutdownComplete",
              "totalDurationMs": totalMs,
              "timestamp": ISO8601DateFormatter().string(from: finalTime)
            ])

            self.rtmpStream = nil
            self.rtmpConnection = nil
            self.pendingPublish = nil

            self.setStatus("stopped")
            print("[ExpoSettings] ✅ Stream stopped (total \(totalMs)ms)")
          }
        }

        return
      }

      // Keep flushing
      DispatchQueue.main.asyncAfter(deadline: .now() + interval) { flushTick() }
    }

    flushTick()
  }
}
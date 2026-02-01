import ExpoModulesCore
import HaishinKit
import AVFoundation
import VideoToolbox

public final class ExpoSettingsModule: Module {

    // MARK: - Core Objects
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?

    // MARK: - State
    private var currentStatus: String = "idle"
    private var operationStartTime: Date?

    // MARK: - Stream Configuration (Portrait 9:16)
    private let videoWidth = 720
    private let videoHeight = 1280
    private let videoBitrate = 4_000_000
    private let audioBitrate = 128_000
    private let frameRate: Float64 = 30
    private let gopSeconds: Int32 = 1

    // MARK: - Audio Session Singleton
    private static var audioSessionConfigured = false

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func definition() -> ModuleDefinition {

        Name("ExpoSettings")

        View(ExpoSettingsView.self) {}

        Events("onStreamStatus", "onStreamTiming")

        Function("getStreamStatus") {
            return self.currentStatus
        }

        Function("getDeviceDimensions") {
            return [
                "streamWidth": Int(self.videoWidth),
                "streamHeight": Int(self.videoHeight),
                "aspectRatio": "9:16"
            ]
        }

        Function("initializePreview") {
            Task { await self.initializePreview() }
        }

        Function("publishStream") { (url: String, streamKey: String) in
            Task { await self.publishStream(url: url, streamKey: streamKey) }
        }

        Function("stopStream") {
            Task { await self.stopStream() }
        }

        Function("forceCleanup") {
            self.cleanup()
            self.setStatus("idle")
        }
    }

    private func setStatus(_ status: String) {
        guard currentStatus != status else { return }

        print("[ExpoSettings] \(currentStatus) → \(status)")
        currentStatus = status

        sendEvent("onStreamStatus", [
            "status": status,
            "timestamp": Self.isoFormatter.string(from: Date())
        ])
    }

    private func setupAudioSession() -> Bool {

        if Self.audioSessionConfigured { return true }

        do {
            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetooth]
            )

            try session.setActive(true)

            Self.audioSessionConfigured = true
            print("[ExpoSettings] Audio session ready")
            return true

        } catch {
            print("[ExpoSettings] Audio session error:", error)
            return false
        }
    }

    private func initializePreview() async {

        print("[ExpoSettings] initializePreview")
        operationStartTime = Date()

        cleanup()
        try? await Task.sleep(nanoseconds: 200_000_000)

        setStatus("previewInitializing")

        guard setupAudioSession() else {
            setStatus("error")
            return
        }

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

        rtmpConnection = connection
        rtmpStream = stream

        // ---------- Stream Base ----------
        stream.sessionPreset = .hd1280x720
        stream.frameRate = frameRate
        stream.videoOrientation = .portrait
        stream.configuration {
            $0.automaticallyConfiguresApplicationAudioSession = true
        }

        // ---------- Audio ----------
        stream.audioSettings = AudioCodecSettings(
            bitRate: audioBitrate
        )

        // ---------- Video ----------
        stream.videoSettings = VideoCodecSettings(
            videoSize: .init(width: videoWidth, height: videoHeight),
            bitRate: videoBitrate,
            profileLevel: kVTProfileLevel_H264_Main_4_1 as String,
            scalingMode: .letterbox,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: gopSeconds,
            allowFrameReordering: nil,
            isHardwareEncoderEnabled: true
        )

        // ---------- Attach Audio ----------
        if let mic = AVCaptureDevice.default(for: .audio) {
            stream.attachAudio(mic)
        }

        // ---------- Attach Camera ----------
        if let cam = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) {
            stream.attachCamera(cam) { unit, _ in
                guard let unit else { return }
                unit.videoOrientation = .portrait
                unit.isVideoMirrored = true
                unit.preferredVideoStabilizationMode = .standard
                unit.colorFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        }

        // ---------- Preview ----------
        if let preview = await ExpoSettingsView.current {
            await preview.attachStream(stream)
        }

        let ms = Int(Date().timeIntervalSince(operationStartTime!) * 1000)

        print("[ExpoSettings] Preview ready in \(ms)ms")
        setStatus("previewReady")

        sendEvent("onStreamTiming", [
            "event": "previewReady",
            "durationMs": ms
        ])
    }

    private func publishStream(url: String, streamKey: String) async {

        guard let connection = rtmpConnection,
              let stream = rtmpStream else {
            setStatus("error")
            return
        }

        operationStartTime = Date()
        setStatus("connecting")

        connection.connect(url)

        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            if connection.connected { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard connection.connected else {
            print("[ExpoSettings] Connect timeout")
            setStatus("error")
            return
        }

        setStatus("connected")
        try? await Task.sleep(nanoseconds: 150_000_000)

        setStatus("publishing")
        stream.publish(streamKey)

        try? await Task.sleep(nanoseconds: 200_000_000)

        let ms = Int(Date().timeIntervalSince(operationStartTime!) * 1000)

        print("[ExpoSettings] STREAM STARTED in \(ms)ms")

        setStatus("started")

        sendEvent("onStreamTiming", [
            "event": "firstDataSent",
            "delayMs": ms,
            "timestamp": Self.isoFormatter.string(from: Date())
        ])
    }

    private func stopStream() async {

        print("[ExpoSettings] stopStream")

        guard let stream = rtmpStream,
              let connection = rtmpConnection else {
            cleanup()
            setStatus("stopped")
            return
        }

        operationStartTime = Date()
        setStatus("stopping")

        // Stop capture
        stream.attachCamera(nil)
        stream.attachAudio(nil)

        // Flush encoder (GOP + 0.5s)
        let flushNs = UInt64(gopSeconds) * 1_000_000_000 + 500_000_000
        try? await Task.sleep(nanoseconds: flushNs)

        // Close stream
        stream.close()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Close socket
        connection.close()

        cleanup()

        let ms = Int(Date().timeIntervalSince(operationStartTime!) * 1000)

        print("[ExpoSettings] STOPPED in \(ms)ms")

        setStatus("stopped")

        sendEvent("onStreamTiming", [
            "event": "shutdownComplete",
            "totalDurationMs": ms,
            "timestamp": Self.isoFormatter.string(from: Date())
        ])
    }

    private func cleanup() {

        print("[ExpoSettings] Cleanup")

        rtmpStream?.attachCamera(nil)
        rtmpStream?.attachAudio(nil)
        rtmpStream?.close()
        rtmpStream = nil

        rtmpConnection?.close()
        rtmpConnection = nil
    }
}

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

      // Registra o view component para o admin se enxergar na live

        View(ExpoSettingsView.self) {
          // não precisa colocar nada aqui se você não tiver Props
        }
        
        Events("onStreamStatus")

        Function("getStreamStatus") {
          return self.currentStreamStatus
        }

        Function("initializePreview") { () -> Void in
              Task {
                  self.currentStreamStatus = "previewInitializing"
                  sendEvent("onStreamStatus", ["status": self.currentStreamStatus])

                do {
                    
                    // 0) Configura e ativa o AVAudioSession
                       let session = AVAudioSession.sharedInstance()
                       do {
                         try session.setCategory(.playAndRecord,
                                                 mode: .default,
                                                 options: [.defaultToSpeaker, .allowBluetooth])
                         try session.setActive(true)
                       } catch {
                         print("[ExpoSettings] AVAudioSession error:", error)
                       }
                    
                    // 1) Conectar ao servidor RTMP, mas não publica
                      let connection = RTMPConnection()
                      self.rtmpConnection = connection
                    
                    // 2) Criar RTMPStream, mas não publica pro servidor ainda
                    let stream = RTMPStream(connection: connection)
                    self.rtmpStream = stream
                    print("[ExpoSettings] RTMPStream initialized")

                    // 3) Configurar captura: frame rate e preset
                    stream.frameRate = 30
                    stream.sessionPreset = .medium
                    stream.configuration { captureSession in
                      captureSession.automaticallyConfiguresApplicationAudioSession = true
                    }
                    
                    // 4) Configurar áudio: anexa microfone
                    if let audioDevice = AVCaptureDevice.default(for: .audio) {
                      print("[ExpoSettings] Attaching audio device")
                      stream.attachAudio(audioDevice)
                    } else {
                      print("[ExpoSettings] No audio device found")
                    }
                    
                    // 5) Configurar vídeo: anexa câmera frontal
                    if let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                            for: .video,
                                                            position: .front) {
                      print("[ExpoSettings] Attaching camera device")
                      stream.attachCamera(camera) { videoUnit, error in
                        guard let unit = videoUnit else {
                          print("[ExpoSettings] attachCamera error:", error?.localizedDescription ?? "unknown")
                          return
                        }
                        unit.isVideoMirrored = true
                        unit.preferredVideoStabilizationMode = .standard
                        unit.colorFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                          
                      }
                        if let preview = await ExpoSettingsView.current {
                            print("[ExpoSettings] Attaching stream to preview view")
                            await preview.attachStream(stream)
                        } else {
                            print("[ExpoSettings] ERROR: Preview view not found!")
                        }
                    } else {
                      print("[ExpoSettings] No camera device found")
                    }

                    //6) Definir configurações de codec
                    print("[ExpoSettings] Setting audio and video codecs")
                    var audioSettings = AudioCodecSettings()
                    audioSettings.bitRate = 128 * 1000
                    stream.audioSettings = audioSettings

                    let videoSettings = VideoCodecSettings(
                     videoSize: .init(width: 1080, height: 1920),
                     bitRate: 4000 * 1000, 
                     profileLevel: kVTProfileLevel_H264_Baseline_4_0 as String,
                     scalingMode: .trim,
                     bitRateMode: .average,
                     maxKeyFrameIntervalDuration: 2,
                     allowFrameReordering: nil,
                     isHardwareEncoderEnabled: true
                    )
                    stream.videoSettings = videoSettings
                }
                  self.currentStreamStatus = "previewReady"
                  sendEvent("onStreamStatus", ["status": self.currentStreamStatus])
              }
            }

            Function("publishStream") { (url: String, streamKey: String) -> Void in
             Task {

               print("[ExpoSettings] Publishing stream to URL: \(url) with key: \(streamKey)")
         
                self.currentStreamStatus = "connecting"
               sendEvent("onStreamStatus", ["status": self.currentStreamStatus])

               // se não houve initializePreview→recria a connection
               if self.rtmpConnection == nil || self.rtmpStream == nil {
                   print("[ExpoSettings] WARNING: Connection or stream not initialized, creating new ones")
                   // Create new connection
                   let connection = RTMPConnection()
                   self.rtmpConnection = connection
                   connection.connect(url)
                   
                   // Create new stream
                   let stream = RTMPStream(connection: connection)
                   self.rtmpStream = stream
                   
                   // Attach to view if available
                   if let preview = await ExpoSettingsView.current {
                       await preview.attachStream(stream)
                   } else {
                       print("[ExpoSettings] ERROR: Preview view not found during publish!")
                   }
               } else {
                   // Use existing connection
                   self.rtmpConnection?.connect(url)
               }
               self.currentStreamStatus = "connected"
               sendEvent("onStreamStatus", ["status": self.currentStreamStatus])

              self.currentStreamStatus = "publishing"
               sendEvent("onStreamStatus", ["status": self.currentStreamStatus])

               self.rtmpStream?.publish(streamKey)
               print("[ExpoSettings] Stream published successfully")

               self.currentStreamStatus = "started"
               sendEvent("onStreamStatus", ["status": self.currentStreamStatus])
              }
            }

              Function("stopStream") { () -> Void in
                Task {
                    print("[ExpoSettings] stopStream called")
                    
                    // Primeiro pare a publicação (se estiver publicando)
                    if let stream = self.rtmpStream {
                        print("[ExpoSettings] Stopping stream publication")
                        stream.close()
                        
                        // Desanexa a câmera e o áudio para liberar recursos
                        stream.attachCamera(nil)
                        stream.attachAudio(nil)
                    }
                    
                    // Depois feche a conexão RTMP
                    if let connection = self.rtmpConnection {
                        print("[ExpoSettings] Closing RTMP connection")
                        connection.close()
                    }
                    
                    // Limpe as referências
                    self.rtmpStream = nil
                    self.rtmpConnection = nil
                    
                    print("[ExpoSettings] Stream and connection closed and resources released")

                    self.currentStreamStatus = "stopped"
                    sendEvent("onStreamStatus", ["status": self.currentStreamStatus])
                }
            }
        }
    }
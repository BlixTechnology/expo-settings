import ExpoModulesCore
import HaishinKit
import RTMPHaishinKit // Adicionado para 2.1.x
import AVFoundation
import VideoToolbox
import Combine // Adicionado para lidar com @Published


public class ExpoSettingsModule: Module {
    private var rtmpConnection: RTMPConnection? //actor
    private var rtmpStream: RTMPStream?
    private var mediaMixer: MediaMixer? // Adicionado para persistir o mixer
    private var currentStreamStatus: String = "stopped"
    private var cancellables = Set<AnyCancellable>() // Para lidar com eventos do actor

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
                         try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                         try session.setActive(true)
                       } catch {
                         print("[ExpoSettings] AVAudioSession error:", error)
                       }
          
                    // 1) Conectar ao servidor RTMP (apenas para inicializar o objeto, não conecta de fato)
                      let connection = RTMPConnection()
                      self.rtmpConnection = connection
                    
                    // 2) Criar RTMPStream, mas não publica pro servidor ainda
                    let stream = RTMPStream(connection: connection)
                    self.rtmpStream = stream
                    print("[ExpoSettings] RTMPStream initialized")


                    // Configuração do mixer para vídeo e áudio
                    let mixer = MediaMixer()
                    self.mediaMixer = mixer // Atribuir o mixer à propriedade da classe

                    // 4) Configurar áudio: anexa microfone
                    if let audioDevice = AVCaptureDevice.default(for: .audio) {
                      print("[ExpoSettings] Attaching audio device")
                        do {
                          try await mixer.attachAudio(audioDevice)
                        } catch {
                          print("[ExpoSettings] Error attaching audio device to mixer:", error)
                        }
                    } else {
                      print("[ExpoSettings] No audio device found")
                    }

                    // 5) Configurar vídeo: anexa câmera frontal
                    if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                      print("[ExpoSettings] Attaching camera device")
                        do {
                            try await mixer.attachVideo(camera) { videoUnit, error in
                                guard let unit = videoUnit else {
                                    print("[ExpoSettings] attachCamera error:", error?.localizedDescription ?? "unknown")
                                    return
                                }
                                unit.isVideoMirrored = true
                                unit.preferredVideoStabilizationMode = .standard
                                unit.colorFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                            }
                        } catch {
                            logger.error(error)
                        }

                        if let preview = await ExpoSettingsView.current {
                            print("[ExpoSettings] Attaching preview view to mixer")
                            await mixer.addOutput(preview)
                        } else {
                            print("[ExpoSettings] ERROR: Preview view not found!")
                        }
                    } else {
                      print("[ExpoSettings] No camera device found")
                    }

                    // 7) 2.1+: iniciar captura explicitamente
                    // Deve ser chamado após todas as entradas e saídas serem anexadas
                    await mixer.startRunning() // obrigatório na 2.1.x

                    // Configurar frame rate para a câmera (se necessário, pois o mixer agora gerencia)
                    try? await mixer.configuration(video: 0) { videoUnit in
                        do {
                          try videoUnit.setFrameRate(30)
                        } catch {
                          logger.error(error)
                        }
                    }

                    // Sets to output frameRate.
                    try await mixer.setFrameRate(30)

                    //6) Definir configurações de codec
                    print("[ExpoSettings] Setting audio and video codecs")
                    var audioSettings = AudioCodecSettings()
                    audioSettings.bitRate = 128 * 1000
                    stream.audioSettings = audioSettings

                    let videoSettings = VideoCodecSettings(
                     videoSize: .init(width: 720, height: 1280),
                     bitRate: 1500 * 1000, 
                     profileLevel: kVTProfileLevel_H264_Baseline_3_1 as String,
                     scalingMode: .trim,
                     bitRateMode: .average,
                     maxKeyFrameIntervalDuration: 2,
                     allowFrameReordering: nil,
                     isHardwareEncoderEnabled: true
                    )
                    stream.videoSettings = videoSettings

                } catch {
                    print("[ExpoSettings] Error during initializePreview:", error)
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
               if self.rtmpConnection == nil || self.rtmpStream == nil || self.mediaMixer == nil {
                   print("[ExpoSettings] WARNING: Connection, stream or mixer not initialized, creating new ones")
                   // Create new connection
                   let connection = RTMPConnection()
                   self.rtmpConnection = connection

                   connection.connect(url)

                   
                   // Create new stream
                   let stream = RTMPStream(connection: connection)
                   self.rtmpStream = stream

                   // Create new mixer
                   let mixer = MediaMixer()
                   self.mediaMixer = mixer
                   
                   // Attach to view if available
                   if let preview = await ExpoSettingsView.current {
                      await mixer.addOutput(preview)
                   } else {
                      print("[ExpoSettings] ERROR: Preview view not found during publish!")
                   }
                   // Iniciar o mixer se não estiver rodando
                   await mixer.startRunning()

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
                    }

                    // Desanexa a câmera e o áudio para liberar recursos usando o mixer
                    if let mixer = self.mediaMixer {
                        print("[ExpoSettings] Detaching audio and video from mixer")
                        await mixer.attachVideo(nil)
                        await mixer.attachAudio(nil)
                        await mixer.stopRunning() // Parar o mixer
                        // Remover a view do output do mixer
                        if let preview = await ExpoSettingsView.current {
                          await mixer.removeOutput(preview)
                        }
                        self.mediaMixer = nil // Limpar a referência do mixer
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
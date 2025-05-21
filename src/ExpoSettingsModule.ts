import { Platform } from 'react-native';
import { requireNativeModule } from 'expo-modules-core';

// Só carrega o native module no iOS; no Android, exporta stubs vazios
const ExpoSettingsModule = Platform.OS === 'ios'
  ? requireNativeModule('ExpoSettings')
  : {
      // Métodos usados pelo seu fluxo de live-stream
      initializePreview: () => Promise.resolve(),  // se for async, senão só () => {}
      startStream: (_url: string, _streamKey: string) => {},
      publishStream: (_url: string, _streamKey: string) => {},
      stopStream: () => {},
    };

export default ExpoSettingsModule;


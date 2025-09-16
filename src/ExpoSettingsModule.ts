import { Platform } from 'react-native';
import { NativeModule, requireNativeModule } from 'expo';
import type { EventSubscription } from 'expo-modules-core';
import { ExpoSettingsEvents } from './ExpoSettings.types';

// Interface do módulo nativo (métodos expostos pelo Swift/Android)
declare class ExpoSettingsNativeModule extends NativeModule<ExpoSettingsEvents> {
  initializePreview(): void | Promise<void>;
  publishStream(url: string, streamKey: string): void | Promise<void>;
  stopStream(): void | Promise<void>;
  getStreamStatus(): Promise<
    | 'previewInitializing'
    | 'previewReady'
    | 'connecting'
    | 'connected'
    | 'publishing'
    | 'started'
    | 'stopped'
  >;

  // herdado de NativeModule, mas declaramos para o stub compilar
  addListener(
    eventName: keyof ExpoSettingsEvents,
    listener: ExpoSettingsEvents[keyof ExpoSettingsEvents]
  ): EventSubscription;
  removeListeners(count: number): void;
}

// iOS: carrega o nativo; Android: stubs seguros (no-op)
const ExpoSettingsModule: ExpoSettingsNativeModule =
  Platform.OS === 'ios'
    ? requireNativeModule<ExpoSettingsNativeModule>('ExpoSettings')
    : ({
        initializePreview: () => {},
        publishStream: (_u: string, _k: string) => {},
        stopStream: () => {},
        getStreamStatus: async () => 'stopped',
        addListener: () => ({ remove() {} } as EventSubscription),
        removeListeners: (_count: number) => {},
      } as unknown as ExpoSettingsNativeModule);

export default ExpoSettingsModule;

// Reexporta o nativo (web resolve para .web.ts se existir)
export { default } from './ExpoSettingsModule';
export { default as ExpoSettingsView } from './ExpoSettingsView';
export * from './ExpoSettings.types';

//Helpers
import type { EventSubscription } from 'expo-modules-core';
import type { LiveChangeEvent } from './ExpoSettings.types';
import ExpoSettingsModule from './ExpoSettingsModule';

export function addLiveListener(
  listener: (event: LiveChangeEvent) => void
): EventSubscription {
  return ExpoSettingsModule.addListener('onStreamStatus', listener);
}

export function initializePreview(): void | Promise<void> {
  return ExpoSettingsModule.initializePreview();
}

export function publishStream(url: string, streamKey: string): void | Promise<void> {
  return ExpoSettingsModule.publishStream(url, streamKey);
}

export function stopStream(): void | Promise<void> {
  return ExpoSettingsModule.stopStream();
}

export async function getStreamStatus(): Promise<string> {
  return await ExpoSettingsModule.getStreamStatus();
}
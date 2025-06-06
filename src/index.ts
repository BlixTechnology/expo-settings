import { EventEmitter, Subscription } from "expo-modules-core";
import ExpoSettingsModule from "./ExpoSettingsModule";
import ExpoSettingsView from './ExpoSettingsView';

const emitter = new EventEmitter(ExpoSettingsModule);

export { ExpoSettingsView };

export type LiveChangeEvent = {
  status:
  | "previewInitializing"
  | "previewReady"
  | "connecting"
  | "connected"
  | "publishing"
  | "started"
  | "stopped";
};

export function addLiveListener(
  listener: (event: LiveChangeEvent) => void
): Subscription {
  return emitter.addListener<LiveChangeEvent>("onStreamStatus", listener);
}

export function initializePreview(): void {
  return ExpoSettingsModule.initializePreview();
}

// ← RENOMEADO startStream → publishStream, agora só publica
export function publishStream(url: string, streamKey: string): void {
  return ExpoSettingsModule.publishStream(url, streamKey);
}

export function stopStream(): void {
  return ExpoSettingsModule.stopStream();
}

export async function getStreamStatus(): Promise<string> {
  return await ExpoSettingsModule.getStreamStatus();
}
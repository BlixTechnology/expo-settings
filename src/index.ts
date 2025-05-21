import { EventEmitter, Subscription } from "expo-modules-core";
import ExpoSettingsModule from "./ExpoSettingsModule";
import ExpoSettingsView from './ExpoSettingsView'; 

const emitter = new EventEmitter(ExpoSettingsModule);

export { ExpoSettingsView };       

export type LiveChangeEvent = {
  status: "started" | "stopped" | "previewReady";
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
export function publishStream(url: String, streamKey: String): void {
  return ExpoSettingsModule.publishStream(url, streamKey);
}

export function stopStream(): void {
  return ExpoSettingsModule.stopStream();
}

export function startStream(url: String, streamKey: String): void {
  return ExpoSettingsModule.startStream(url, streamKey);
 }
 

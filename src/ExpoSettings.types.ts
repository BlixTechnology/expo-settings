import type { StyleProp, ViewStyle } from 'react-native';

export type ExpoSettingsViewProps = {
  style?: StyleProp<ViewStyle>;
};

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

export type ExpoSettingsEvents = {
  onStreamStatus: (event: LiveChangeEvent) => void;
};
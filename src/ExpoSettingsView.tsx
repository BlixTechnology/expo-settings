import { requireNativeView } from 'expo';
import * as React from "react";
import {
  ExpoSettingsViewProps,
} from "./ExpoSettings.types";

const NativeView: React.ComponentType<ExpoSettingsViewProps> =
  requireNativeView('ExpoSettings');

  export default function ExpoSettingsView(props: ExpoSettingsViewProps) {
    return <NativeView {...props} />;
  }

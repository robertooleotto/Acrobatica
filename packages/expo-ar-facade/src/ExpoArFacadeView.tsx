import { requireNativeViewManager } from "expo-modules-core";
import * as React from "react";
import { View } from "react-native";
import type { ExpoArFacadeViewProps, ExpoArFacadeViewRef } from "./ExpoArFacade.types";

const NativeView: React.ComponentType<ExpoArFacadeViewProps> | null = (() => {
  try { return requireNativeViewManager("ExpoArFacade"); } catch { return null; }
})();

const ExpoArFacadeView = React.forwardRef<ExpoArFacadeViewRef, ExpoArFacadeViewProps>(
  function ExpoArFacadeView(props, ref) {
    if (!NativeView) return <View style={[{ backgroundColor: "#1a1a1a" }, props.style]} />;
    const NativeWithRef = NativeView as unknown as React.ComponentType<
      ExpoArFacadeViewProps & { ref?: React.Ref<ExpoArFacadeViewRef> }
    >;
    return <NativeWithRef ref={ref} {...props} />;
  }
);

export default ExpoArFacadeView;

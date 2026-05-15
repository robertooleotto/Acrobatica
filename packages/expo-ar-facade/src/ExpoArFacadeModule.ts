import { requireNativeModule } from "expo-modules-core";
import type { ExpoArFacadeModuleApi } from "./ExpoArFacade.types";

let nativeModule: ExpoArFacadeModuleApi | null = null;
try { nativeModule = requireNativeModule<ExpoArFacadeModuleApi>("ExpoArFacade"); } catch { nativeModule = null; }

const stub: ExpoArFacadeModuleApi = {
  isSupported: () => false,
  hasLidar: () => false,
  isRoomPlanSupported: () => false,
  requestAuthorization: async () => false,
};

export default nativeModule ?? stub;

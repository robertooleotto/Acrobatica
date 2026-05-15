import { useReducer } from "react";
import type { Point3D, Polygon3D, Quad3D, FacciataScan } from "@acrobatica/shared";

export type ScanPhase =
  | "placing_corners" | "review_corners"
  | "placing_excluded" | "placing_extra" | "result";

export interface PolygonInProgress {
  kind: "excluded" | "extra";
  points: Point3D[];
  label?: string;
}

export interface ScanState {
  phase: ScanPhase;
  corners: Point3D[];
  inProgress: PolygonInProgress | null;
  excluded: Array<{ id: string; label?: string; polygon: Polygon3D }>;
  extras: Array<{ id: string; label?: string; polygon: Polygon3D }>;
}

export type ScanAction =
  | { type: "add_point"; point: Point3D }
  | { type: "set_corners"; corners: Quad3D }
  | { type: "remove_last" }
  | { type: "start_excluded"; label?: string }
  | { type: "start_extra"; label?: string }
  | { type: "close_polygon" }
  | { type: "cancel_polygon" }
  | { type: "go_to_result" }
  | { type: "back_to_corners" }
  | { type: "reset" };

export const INITIAL_STATE: ScanState = {
  phase: "placing_corners", corners: [], inProgress: null, excluded: [], extras: []
};

function uid(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function scanReducer(state: ScanState, action: ScanAction): ScanState {
  switch (action.type) {
    case "add_point": {
      if (state.phase === "placing_corners") {
        if (state.corners.length >= 4) return state;
        const next = [...state.corners, action.point];
        return { ...state, corners: next, phase: next.length === 4 ? "review_corners" : "placing_corners" };
      }
      if (state.inProgress) {
        return { ...state, inProgress: { ...state.inProgress, points: [...state.inProgress.points, action.point] } };
      }
      return state;
    }
    case "set_corners":
      return { ...state, corners: action.corners as unknown as Point3D[], phase: "review_corners" };
    case "remove_last": {
      if (state.phase === "placing_corners" && state.corners.length > 0)
        return { ...state, corners: state.corners.slice(0, -1) };
      if (state.inProgress && state.inProgress.points.length > 0)
        return { ...state, inProgress: { ...state.inProgress, points: state.inProgress.points.slice(0, -1) } };
      return state;
    }
    case "start_excluded":
      return { ...state, phase: "placing_excluded",
        inProgress: { kind: "excluded", points: [], ...(action.label !== undefined ? { label: action.label } : {}) } };
    case "start_extra":
      return { ...state, phase: "placing_extra",
        inProgress: { kind: "extra", points: [], ...(action.label !== undefined ? { label: action.label } : {}) } };
    case "close_polygon": {
      if (!state.inProgress || state.inProgress.points.length < 3) return state;
      const entry = {
        id: uid(),
        polygon: state.inProgress.points as Polygon3D,
        ...(state.inProgress.label !== undefined ? { label: state.inProgress.label } : {})
      };
      return state.inProgress.kind === "excluded"
        ? { ...state, phase: "review_corners", inProgress: null, excluded: [...state.excluded, entry] }
        : { ...state, phase: "review_corners", inProgress: null, extras: [...state.extras, entry] };
    }
    case "cancel_polygon":
      return { ...state, phase: "review_corners", inProgress: null };
    case "go_to_result":
      return { ...state, phase: "result" };
    case "back_to_corners":
      return { ...state, phase: "review_corners" };
    case "reset":
      return INITIAL_STATE;
  }
}

export function useScanReducer() { return useReducer(scanReducer, INITIAL_STATE); }

export function buildFacciataScan(state: ScanState): FacciataScan | null {
  if (state.corners.length !== 4) return null;
  return {
    corners: state.corners as unknown as Quad3D,
    excluded: state.excluded, extras: state.extras, capturedAt: Date.now()
  };
}

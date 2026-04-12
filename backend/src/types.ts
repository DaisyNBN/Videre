export interface HazardReport {
  user_id: string;
  lat: number;
  lng: number;
  type: string;
  description: string;
  timestamp: string;
  verified: boolean;
}

export interface NavRequest {
  user_id: string;
  route_id: string;
  location: { lat: number; lng: number };
  heading_degrees: number;
  obstacles: Obstacle[];
  speed: "walking" | "stopped";
}

export interface Obstacle {
  label: string;
  position: "left" | "center" | "right";
  distance_estimate: "near" | "mid" | "far";
}

export interface NavResponse {
  instruction: string;
  urgency: "low" | "medium" | "high";
  haptic_pattern: "none" | "single_tap" | "double_tap" | "continuous";
  next_checkpoint: string | null;
  distance_to_next_m: number | null;
  fallback_used: boolean;
}

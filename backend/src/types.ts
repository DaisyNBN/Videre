export type HazardReport = {
  user_id: string;
  lat: number;
  lng: number;
  type: string;
  description: string;
  timestamp: string;
  verified: boolean;
}

export type NavRequest = {
  user_id: string;
  route_id: string;
  location: { lat: number; lng: number };
  heading_degrees: number;
  obstacles: Obstacle[];
  speed: "walking" | "stopped";
}

export type Obstacle = {
  label: string;
  position: "left" | "center" | "right";
  distance_estimate: "near" | "mid" | "far";
}

export type NavResponse = {
  instruction: string;
  urgency: "low" | "medium" | "high";
  haptic_pattern: "none" | "single_tap" | "double_tap" | "continuous";
  next_checkpoint: string | null;
  distance_to_next_m: number | null;
  fallback_used: boolean;
}

// ==============================
// Base Spatial Types
// ==============================
export type Vector3 = {
  x: number;
  y: number;
  z: number;
};

// ==============================
// Scan Data Types (iOS)
// ==============================
export type ScanPoint = Vector3 & {
  timestamp?: number;
};

// ==============================
// Landmark Types
// ==============================
export type LandmarkType =
  | "door"
  | "wall"
  | "stair"
  | "elevator"
  | "obstacle"
  | "exit"
  | "unknown";

export type Landmark = Vector3 & {
  id?: string;
  type: LandmarkType;
  label?: string;
  confidence?: number;
  source?: "user" | "gemini";
};

// ==============================
// AI Detection Types
// ==============================
export type AIObjectDetection = {
  label: string;
  confidence: number;
  boundingBox?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
};

// ==============================
// Navigation Graph Types
// ==============================
export type NodeType = "path" | "landmark" | "start" | "end";

export type MapNode = Vector3 & {
  id: string;
  type: NodeType;
  label?: string;
};

export type MapEdge = {
  from: string;
  to: string;
  distance: number;
  walkable: boolean;
};

export type RoomMap = {
  id: string;
  roomName: string;
  createdBy: string;
  createdAt: string;
  nodes: MapNode[];
  edges: MapEdge[];
  version: number;
};

// ==============================
// API Request Types
// ==============================
export type ScanUploadRequest = {
  userId: string;
  roomName: string;
  points: ScanPoint[];
  landmarks: Landmark[];
};

export type AIProcessRequest = {
  imageUrl: string;
  depthData?: unknown;
  cameraPose: Vector3;
};

// ==============================
// Verification System Types
// ==============================
export type VerificationStatus = "pending" | "verified" | "rejected";

export type LandmarkVerification = {
  landmarkId: string;
  verifiedBy: string;
  status: VerificationStatus;
  notes?: string;
};

// ==============================
// Pathfinding Types
// ==============================
export type PathRequest = {
  mapId: string;
  startNodeId: string;
  endNodeId: string;
};

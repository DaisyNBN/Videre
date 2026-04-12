# TypeScript Types – Indoor Navigation System

```ts
// ==============================
// 1. Base Spatial Types
// ==============================
export type Vector3 = {
  x: number;
  y: number;
  z: number;
};

// ==============================
// 2. Scan Data Types (iOS)
// ==============================
export type ScanPoint = Vector3 & {
  timestamp?: number;
};

// ==============================
// 3. Landmark Types
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
  confidence?: number; // AI confidence
  source?: "user" | "gemini";
};

// ==============================
// 4. AI Detection Types
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
// 5. Navigation Graph Types
// ==============================
export type NodeType =
  | "path"
  | "landmark"
  | "start"
  | "end";

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
// 6. API Request Types
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
// 7. Verification System Types
// ==============================
export type VerificationStatus =
  | "pending"
  | "verified"
  | "rejected";

export type LandmarkVerification = {
  landmarkId: string;
  verifiedBy: string;
  status: VerificationStatus;
  notes?: string;
};

// ==============================
// 8. Pathfinding Types
// ==============================
export type PathRequest = {
  mapId: string;
  startNodeId: string;
  endNodeId: string;
};
```

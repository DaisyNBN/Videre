# API Payload From Phone and LiDAR Scanner

This document defines what data the backend API should receive from the phone scanner.

The payload is split into three groups:

- session and device metadata
- spatial trajectory and landmarks
- perception evidence (camera and LiDAR)

## 1. Session and Device Metadata

Include context needed for traceability and processing.

- `scanId`: unique scan UUID
- `userId`: user identifier
- `roomName`: human-readable location label
- `startedAt`: scan start timestamp
- `endedAt`: scan end timestamp
- `device.model`: device model
- `device.osVersion`: OS version
- `device.appVersion`: app version
- `arTrackingQuality`: tracking summary (`good`, `limited`, `relocalizing`)
- `coordinateSystem`: world origin and units (meters)

## 2. Spatial Trajectory (Core Graph Input)

Use sampled points from AR tracking.

- `points`: array of sampled positions
- each point should include:
  - `x`, `y`, `z`
  - `timestamp`
- optional quality per point:
  - `horizontalAccuracy`
  - `verticalAccuracy`
  - `trackingState`

## 3. Landmarks (Manual and AI-Ready)

Collect user-tagged landmarks to improve map quality.

- `landmarks`: array of landmarks
- each landmark should include:
  - `type`
  - `label`
  - `x`, `y`, `z`
  - `source` (`user`)
  - `timestamp`

## 4. LiDAR and Depth Evidence

Provide depth evidence for hazard and geometry confidence.

- `depthSamples` or depth snapshots:
  - `timestamp`
  - `cameraPose`
  - `depthUrl` (or compressed depth blob)
- optional geometry hints:
  - floor/wall planes
  - confidence values
- optional obstacle candidates:
  - region or bounding box
  - estimated distance

## 5. Image Keyframes for AI Analysis

Send selected keyframes instead of full video.

- `keyframes`: array of selected frames
- each keyframe should include:
  - `imageUrl` or `uploadId`
  - `timestamp`
  - `cameraPose`
  - optional camera intrinsics (`fx`, `fy`, `cx`, `cy`)

## 6. Upload Integrity and Sync Safety

Include data needed for robust retry and ordering.

- `sequenceNumber`: chunk order
- `checksum`: chunk or payload hash
- `offlineSync`: whether upload came from offline queue
- `retryCount`: retry attempts
- `idempotencyKey`: deduplication key

## 7. Recommended MVP JSON Payload

```json
{
  "scanId": "uuid",
  "userId": "uuid",
  "roomName": "Library-2F-East",
  "startedAt": "2026-04-12T09:10:00Z",
  "endedAt": "2026-04-12T09:12:10Z",
  "device": {
    "model": "iPhone15,3",
    "osVersion": "iOS 19.0",
    "appVersion": "0.3.0"
  },
  "points": [
    { "x": 0.0, "y": 0.0, "z": 0.0, "timestamp": 1712913000123 },
    { "x": 0.4, "y": 0.0, "z": 0.1, "timestamp": 1712913000450 }
  ],
  "landmarks": [
    {
      "type": "door",
      "label": "Main door",
      "x": 2.1,
      "y": 0.0,
      "z": -1.2,
      "source": "user"
    }
  ],
  "keyframes": [
    {
      "imageUrl": "https://storage.example.com/kf_001.jpg",
      "timestamp": 1712913000500,
      "cameraPose": { "x": 0.4, "y": 0.0, "z": 0.1 }
    }
  ],
  "depthSamples": [
    {
      "timestamp": 1712913000520,
      "cameraPose": { "x": 0.4, "y": 0.0, "z": 0.1 },
      "depthUrl": "https://storage.example.com/d_001.bin"
    }
  ]
}
```

## 8. Practical Guidance

- Sample path points at a stable rate (for example 5 to 10 Hz).
- Capture keyframes sparsely (for example every 1 to 2 meters or at scene changes).
- Use chunked uploads for large scans.
- Validate all coordinates are finite numbers.
- Ensure timestamps are monotonic within each scan.

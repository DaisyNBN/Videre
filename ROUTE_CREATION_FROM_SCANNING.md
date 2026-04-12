# Direct Route Creation from LiDAR Scanning Implementation

## Overview
Routes are now created directly during scanning by recording coordinates and LiDAR data at rapid intervals (4 Hz), providing the most accurate indoor navigation paths without waiting for post-scan graph building.

## Key Changes

### Backend Implementation

#### 1. **New Schema for Waypoint-Based Scans** 
- **File**: [backend/src/schemas/scans.ts](backend/src/schemas/scans.ts)
- Added `Waypoint` struct with fields:
  - `x, y, z`: 3D coordinates from LiDAR
  - `timestamp`: Collection time
  - `depthConfidence`: LiDAR depth confidence (0-1)
  - `lidarClassification`: Optional mesh classification (wall, floor, ceiling, mapped, unknown)
- Added `scanCreateWithRouteBodySchema` for scan uploads with route waypoints
- Includes `createRouteImmediately` flag (default: true)

#### 2. **New Route Creation Service**
- **File**: [backend/src/services/processScanRoute.ts](backend/src/services/processScanRoute.ts)
- `createRouteFromScanWaypoints()`: Processes collected waypoints into navigation route
  - Downsamples waypoints to max 50 nodes (configurable)
  - Filters waypoints < 0.3m apart to avoid redundant nodes
  - Creates map nodes alternating between `start`, `path`, and `end` types
  - Establishes edges with Euclidean distances
  - Stores route checkpoints for navigation instruction generation
- Returns `CreatedScanRoute` with route ID, map ID, and waypoint count

#### 3. **New Scan Upload Endpoint**
- **File**: [backend/routes/scans.ts](backend/routes/scans.ts)
- New endpoint: `POST /api/scans/with-route`
- Accepts scan payload with embedded waypoints
- Creates scan AND immediately generates route from waypoints
- Response includes both `scanId` and `route` object with:
  - `routeId`: Unique route identifier
  - `mapId`: Associated map
  - `waypointCount`: Number of waypoints collected
  - `waypoints`: Full waypoint data with confidence metrics

### iOS Implementation

#### 1. **Enhanced Scan Payload**
- **File**: [Videre_ios_app/Services/ScanPayLoad.swift](Videre_ios_app/Services/ScanPayLoad.swift)
- Added `Waypoint` struct (mirrors backend schema)
- Extended `ScanPayload` with:
  - `waypoints`: Array of collected waypoints
  - `createRouteImmediately`: Route creation flag

#### 2. **Rapid LiDAR Waypoint Collection**
- **File**: [Videre_ios_app/Services/ScanService.swift](Videre_ios_app/Services/ScanService.swift)
- New property: `waypointInterval = 0.25 seconds` (4 Hz sampling)
- New method: `collectWaypoint(frame:)`
  - Called during every AR frame after waypoint interval elapses
  - Captures current camera position from AR frame transform
  - Extracts depth confidence from LiDAR depth map
  - Classifies point as "mapped" when mesh data available
  - Tracks waypoint count for UI display
- Integration in `onARFrame()`:
  ```swift
  if now - lastWaypointTime >= waypointInterval {
      lastWaypointTime = now
      collectWaypoint(frame: frame)
  }
  ```

#### 3. **Intelligent Upload Routing**
- **File**: [Videre_ios_app/Services/ScanService.swift](Videre_ios_app/Services/ScanService.swift)
- Modified `buildPayload()`:
  - Includes waypoints if collected (>0)
  - Sets `createRouteImmediately = true` for waypoint scans
- Modified `upload()`:
  - Selects endpoint based on waypoint presence:
    - With waypoints: `ingest-scan-with-route`
    - Without waypoints: `ingest-scan`
  - Extracts route data from response when available:
    ```swift
    if let route = routeData["route"] as? [String: Any],
       let waypointRouteId = route["routeId"] as? String {
        routeId = waypointRouteId
        // Skip graph-based route generation
    }
    ```

#### 4. **Real-Time Waypoint Feedback**
- **File**: [Videre_ios_app/Services/ScanService.swift](Videre_ios_app/Services/ScanService.swift)
- New @Published property: `waypointCount`
- Updated during scanning for live UI feedback
- **File**: [Videre_ios_app/Views/ScanView.swift](Videre_ios_app/Views/ScanView.swift)
- Added route waypoints status card (purple indicator):
  - Shows "Route waypoints: X" when count > 0
  - Displays only during active scanning
  - Positioned below scanning statistics

## Workflow

### During Scanning:
1. User starts scan of room
2. ScanService begins collecting waypoints at 4 Hz
3. Each waypoint captures:
   - Current AR camera position (x, y, z)
   - LiDAR depth confidence
   - Mesh classification if available
4. UI shows live waypoint count
5. User continues scanning, providing dense position sampling

### During Upload:
1. Scan completes, user taps "Stop and upload"
2. iOS app detects waypoints in payload
3. Sends to `POST /api/scans/with-route` endpoint
4. Backend receives waypoints and:
   - Creates scan record (normal flow)
   - Immediately processes waypoints
   - Downsamples to ~50 key nodes
   - Creates map nodes and edges from waypoint sequence
   - Generates route with proper start/end markers
5. Response includes route data
6. iOS extracts `routeId` and skips secondary route generation
7. Route ready immediately after upload (no additional latency)

## Benefits

✅ **Faster Route Creation**: Route built during scanning, not after  
✅ **More Accurate**: Rapid 4 Hz sampling captures path details  
✅ **Higher Confidence**: Direct LiDAR coordinates vs. post-processed points  
✅ **Reduced Latency**: No waiting for graph analysis  
✅ **Better UX**: Live feedback of waypoint collection  
✅ **Fallback Support**: Non-waypoint scans still work normally  

## Configuration

### Waypoint Sampling Rate:
```swift
private let waypointInterval: TimeInterval = 0.25  // 4 samples/second
```
Adjust in ScanService.swift for more/less dense sampling

### Maximum Waypoints per Route:
```swift
const MAX_WAYPOINTS = 50;  // In processScanRoute.ts
```
Adjust to balance accuracy vs. performance

### Minimum Waypoint Spacing:
```swift
const MIN_WAYPOINT_SPACING = 0.3;  // in meters
```
Filters redundant waypoints within 0.3m

## Testing

1. Start a room scan
2. Walk slowly through space, ensuring LiDAR is active (marked as cyan indicator)
3. Watch waypoint counter increment in real-time
4. Complete scan and upload
5. Check that route was created from waypoints (look for route in response)
6. Verify route starts at first collected waypoint and ends at last

## Notes

- Waypoint collection continues during entire scan duration
- Waypoints are optimized (downsampled) before being converted to navigation nodes
- If waypoint collection fails, scan still uploads normally (fallback behavior)
- Route can be manually refined after upload if needed
- LiDAR must be enabled for accurate waypoint collection

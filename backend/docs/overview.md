# Indoor Navigation for Blind Users – Project Overview

## 1. Overview

This project is an assistive indoor navigation system designed to help blind and visually impaired users move safely and independently through indoor environments. The system combines mobile sensor data, AI-based scene understanding, and crowd verification to build and maintain shared indoor maps.

The core idea is to transform real-world spaces into structured, navigable graphs that can be reused by multiple users.

---

## 2. Goals

- Enable blind users to navigate indoor environments safely
- Build reusable maps of real-world spaces
- Use AI to identify and label objects in environments
- Allow community-based verification and improvement of maps
- Provide turn-by-turn audio and haptic guidance

---

## 3. Core Concept

The system converts raw sensor input into structured navigation data:

- Movement paths become graph nodes
- Detected or tagged objects become landmarks
- Connections between points become edges

This creates a graph-based representation of indoor spaces.

---

## 4. System Architecture

### Client (iOS App)

- Captures motion and environment data using ARKit
- Records camera frames and device position
- Allows users to tag landmarks (doors, stairs, obstacles)
- Sends scan data to backend API

### Backend (Node.js + TypeScript)

- Receives scan uploads
- Validates and processes data
- Sends keyframes to Google Cloud Vision API for object detection
- Builds navigation graphs
- Stores structured maps in database

### AI Layer

- Google Cloud Vision API processes images
- Returns object labels and confidence scores
- Helps identify landmarks and hazards
- Google Gemini generates natural-language navigation guidance

### Database Layer

- Stores nodes, edges, landmarks, and verification data
- Stores map versions and user contributions

---

## 5. Data Pipeline

1. User scans environment using iOS app
2. ARKit tracks position and camera frames
3. App collects:
   - Path points
   - Camera images (keyframes)
   - User-defined landmarks
4. Data is sent to backend API
5. Backend processes:
   - Validates input
   - Sends images to Vision API
   - Converts raw path into nodes
   - Attaches AI-generated labels
6. Structured graph is stored in database
7. Other users load and navigate the map
8. New users verify and refine map accuracy

---

## 6. iOS Capture System

The iOS app uses ARKit-based tracking to capture:

- 3D position over time (user movement path)
- Camera frames for AI analysis
- Depth data when available (LiDAR devices)
- User-triggered landmarks (tap or voice input)

Output is converted into a structured JSON payload containing:

- Scan points (Vector3 positions)
- Landmarks (type, label, position)
- Metadata (room name, device and timing info)

---

## 7. iOS Scanning Process Optimization

The scanning system is optimized to minimize bandwidth while capturing complete spatial coverage:

### Keyframe Capture Strategy

- **Position Threshold: 1.5 meters** - New image captured when user walks 1.5m from last keyframe location
- **Rotation Threshold: 180 degrees** - Captures image when facing opposite direction (for interior wall mapping)
- **Time Fallback: 5 seconds maximum** - Captures at least one image every 5 seconds
- **Cache Expiration: 5 hours** - Allows image refresh after 5 hours for extended scans

### Continuous Data Collection

- **LiDAR Trajectory Points: Every 1 second** - Position recorded at ~1 Hz regardless of keyframe captures
- **Depth Samples: Every 1 second** - Full depth maps for 3D reconstruction
- **Result: Dense spatial coverage** - Combined keyframes + continuous depth = complete interior mapping

### Bandwidth Optimization

- Reduces keyframe rate from 2 Hz (old) to smart capture (position + rotation based)
- Images only captured in different locations, not on head rotation alone
- ~75% bandwidth reduction while maintaining full 3D data coverage
- Continuous LiDAR ensures no spatial gaps

### Why This Approach Works for Interior Buildings

- **Position-based keyframes** capture visual features (walls, doors, textures) at key locations
- **180° rotation captures** walls from opposite angles when user turns around
- **1-second LiDAR sampling** provides dense depth data between keyframes
- **Combined result** = Complete interior 3D reconstruction without wasted images

---

## 8. Backend Processing (Vision + Gemini)

The backend sends selected images to Google Cloud Vision API to:

- Detect objects in each frame
- Identify doors, obstacles, furniture, and signs
- Return labeled objects with confidence scores

These results are then:

- Mapped into spatial coordinates
- Converted into landmarks
- Attached to the navigation graph

---

## 9. Data Model

### Vector3

- x, y, z coordinates

### ScanPoint

- Position data from AR tracking

### Landmark

- Position + type + label + confidence
- Source: user or AI

### MapNode

- Represents navigable points or landmarks
- Includes type (path, landmark, start, end)

### MapEdge

- Connection between nodes
- Includes distance and walkability

### RoomMap

- Full graph representation of a space
- Includes nodes, edges, metadata, and versioning

---

## 10. Verification System

To improve accuracy and safety:

- Users can confirm or reject detected landmarks
- Each landmark has a confidence score
- Community validation increases reliability
- Maps evolve over time through edits and updates

Verification states:

- pending
- verified
- rejected

---

## 10. Navigation System

The system provides navigation by:

1. Identifying user position in the graph
2. Finding destination node
3. Computing optimal path using A\* algorithm
4. Translating path into instructions:
   - “Walk forward”
   - “Turn left”
   - “Obstacle ahead”

Output is delivered via audio and haptic feedback.

---

## 11. Tech Stack

### Mobile

- iOS (Swift)
- ARKit for motion tracking

### Backend

- Node.js with TypeScript
- Fastify or Express

### Database

- Supabase (Postgres + storage)

### AI

- Google Cloud Vision API (image detections)
- Google Gemini API (navigation text instructions)

---

## 12. Core NPM Packages

Required:

- fastify or express
- @supabase/supabase-js
- zod
- pathfinding
- @google/generative-ai

Optional:

- socket.io (real-time updates)
- uuid (ID generation)
- winston (logging)

---

## 13. Development Phases

### Phase 1 – MVP Mapping

- Capture movement paths
- Add manual landmarks
- Store and retrieve maps

### Phase 2 – AI Enhancement

- Integrate Vision API
- Auto-detect objects
- Attach labels to landmarks

### Phase 3 – Navigation

- Implement pathfinding
- Add audio instructions
- Basic indoor routing

### Phase 4 – Verification System

- Allow multiple users to refine maps
- Confidence scoring system
- Map versioning

### Phase 5 – Scaling

- Multi-building support
- Real-time updates
- Improved AI accuracy

---

## 14. Risks and Challenges

- AR tracking drift in large spaces
- Inaccurate AI object detection
- Changing real-world environments
- Battery and performance limitations on mobile devices
- Safety-critical navigation requirements

---

## 15. Future Improvements

- Full indoor GPS-like experience
- Voice-controlled navigation queries
- Real-time hazard detection
- Wearable device integration
- Improved multi-user spatial anchoring

---

## 16. Summary

This system transforms raw mobile sensor data into structured indoor navigation graphs enhanced with AI labeling and community verification. The result is a continuously improving indoor mapping network designed specifically to assist blind and visually impaired users in real-world navigation.

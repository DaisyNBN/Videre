# Postgres Schema Proposal (Based on Current Types)

This schema separates scan-time ingestion data from canonical map/graph data, then layers verification and hazard reporting on top.

## 1. Enums

- `landmark_type`: `door`, `wall`, `stair`, `elevator`, `obstacle`, `exit`, `unknown`
- `landmark_source`: `user`, `gemini`
- `node_type`: `path`, `landmark`, `start`, `end`
- `verification_status`: `pending`, `verified`, `rejected`

## 2. Core Map Graph Tables

### room_maps

- `id uuid primary key`
- `room_name text not null`
- `created_by uuid not null`
- `created_at timestamptz not null default now()`
- `version int not null default 1`

### map_nodes

- `id uuid primary key`
- `room_map_id uuid not null references room_maps(id) on delete cascade`
- `type node_type not null`
- `label text null`
- `x double precision not null`
- `y double precision not null`
- `z double precision not null`

### map_edges

- `id uuid primary key`
- `room_map_id uuid not null references room_maps(id) on delete cascade`
- `from_node_id uuid not null references map_nodes(id) on delete cascade`
- `to_node_id uuid not null references map_nodes(id) on delete cascade`
- `distance double precision not null check (distance >= 0)`
- `walkable boolean not null default true`
- `unique (room_map_id, from_node_id, to_node_id)`

## 3. Landmarks and Verification Tables

### landmarks

- `id uuid primary key`
- `room_map_id uuid not null references room_maps(id) on delete cascade`
- `type landmark_type not null`
- `label text null`
- `confidence double precision null check (confidence between 0 and 1)`
- `source landmark_source not null default user`
- `x double precision not null`
- `y double precision not null`
- `z double precision not null`
- `status verification_status not null default pending`
- `created_at timestamptz not null default now()`

### landmark_verifications

- `id uuid primary key`
- `landmark_id uuid not null references landmarks(id) on delete cascade`
- `verified_by uuid not null`
- `status verification_status not null`
- `notes text null`
- `created_at timestamptz not null default now()`
- `unique (landmark_id, verified_by)`

## 4. Scan Ingestion Pipeline Tables

### scans

- `id uuid primary key`
- `user_id uuid not null`
- `room_name text not null`
- `processing_status text not null default uploaded`
- `created_at timestamptz not null default now()`

### scan_points

- `id bigserial primary key`
- `scan_id uuid not null references scans(id) on delete cascade`
- `timestamp_ms bigint null`
- `x double precision not null`
- `y double precision not null`
- `z double precision not null`

### scan_landmarks

- `id uuid primary key`
- `scan_id uuid not null references scans(id) on delete cascade`
- `type landmark_type not null`
- `label text null`
- `confidence double precision null check (confidence between 0 and 1)`
- `source landmark_source not null default user`
- `x double precision not null`
- `y double precision not null`
- `z double precision not null`

### ai_detections

- `id bigserial primary key`
- `scan_id uuid not null references scans(id) on delete cascade`
- `label text not null`
- `confidence double precision not null check (confidence between 0 and 1)`
- `bbox_x double precision null`
- `bbox_y double precision null`
- `bbox_width double precision null`
- `bbox_height double precision null`
- `created_at timestamptz not null default now()`

## 5. Existing App-Level Types Table

### hazard_reports

- `id bigserial primary key`
- `user_id uuid not null`
- `lat double precision not null`
- `lng double precision not null`
- `type text not null`
- `description text not null`
- `timestamp timestamptz not null`
- `verified boolean not null default false`

## 6. Notes for Navigation Request/Response Types

`NavRequest` and `NavResponse` are runtime/session-oriented. They do not need persistence unless you want analytics/history.

If needed later, add:

- `nav_sessions`
- `nav_events`

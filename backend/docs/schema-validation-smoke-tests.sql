-- Validate schema alignment and basic write paths after running align-schema-to-docs.sql
-- Run this script in Supabase SQL Editor.
-- It performs read-only checks and rollback-safe write checks.
-- =========================================================
-- 1) Enum value checks
-- =========================================================
SELECT t.typname AS enum_name,
    string_agg(
        e.enumlabel,
        ', '
        ORDER BY e.enumsortorder
    ) AS enum_values
FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
WHERE t.typname IN (
        'landmark_type',
        'landmark_source',
        'node_type',
        'verification_status'
    )
GROUP BY t.typname
ORDER BY t.typname;
-- =========================================================
-- 2) Required table checks
-- =========================================================
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
    AND table_name IN (
        'scans',
        'scan_points',
        'scan_landmarks',
        'ai_detections',
        'room_maps',
        'map_nodes',
        'map_edges',
        'landmarks',
        'landmark_verifications',
        'hazard_reports'
    )
ORDER BY table_name;
-- =========================================================
-- 3) Required column checks
-- =========================================================
SELECT table_name,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
    AND (
        (
            table_name = 'scans'
            AND column_name IN (
                'id',
                'room_name',
                'processing_status',
                'created_at'
            )
        )
        OR (
            table_name = 'scan_points'
            AND column_name IN ('id', 'scan_id', 'timestamp_ms', 'x', 'y', 'z')
        )
        OR (
            table_name = 'scan_landmarks'
            AND column_name IN (
                'id',
                'scan_id',
                'type',
                'label',
                'confidence',
                'source',
                'x',
                'y',
                'z'
            )
        )
        OR (
            table_name = 'ai_detections'
            AND column_name IN (
                'id',
                'scan_id',
                'label',
                'confidence',
                'bbox_x',
                'bbox_y',
                'bbox_width',
                'bbox_height',
                'created_at'
            )
        )
        OR (
            table_name = 'room_maps'
            AND column_name IN (
                'id',
                'room_name',
                'created_by',
                'created_at',
                'version'
            )
        )
        OR (
            table_name = 'map_nodes'
            AND column_name IN (
                'id',
                'room_map_id',
                'type',
                'label',
                'x',
                'y',
                'z'
            )
        )
        OR (
            table_name = 'map_edges'
            AND column_name IN (
                'id',
                'room_map_id',
                'from_node_id',
                'to_node_id',
                'distance',
                'walkable'
            )
        )
        OR (
            table_name = 'landmarks'
            AND column_name IN (
                'id',
                'room_map_id',
                'type',
                'label',
                'confidence',
                'source',
                'x',
                'y',
                'z',
                'status',
                'created_at'
            )
        )
        OR (
            table_name = 'landmark_verifications'
            AND column_name IN (
                'id',
                'landmark_id',
                'verified_by',
                'status',
                'notes',
                'created_at'
            )
        )
        OR (
            table_name = 'hazard_reports'
            AND column_name IN (
                'id',
                'lat',
                'lng',
                'type',
                'description',
                'timestamp',
                'verified'
            )
        )
    )
ORDER BY table_name,
    column_name;
-- =========================================================
-- 4) Constraint checks
-- =========================================================
SELECT conrelid::regclass::text AS table_name,
    conname AS constraint_name,
    pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname IN (
        'map_edges_room_map_from_to_key',
        'landmark_verifications_landmark_verified_by_key',
        'scan_points_scan_id_fkey',
        'scan_landmarks_scan_id_fkey',
        'ai_detections_scan_id_fkey',
        'map_nodes_room_map_id_fkey',
        'map_edges_room_map_id_fkey',
        'map_edges_from_node_id_fkey',
        'map_edges_to_node_id_fkey',
        'landmarks_room_map_id_fkey',
        'landmark_verifications_landmark_id_fkey'
    )
ORDER BY table_name,
    constraint_name;
-- =========================================================
-- 5) Rollback-safe write smoke tests
-- =========================================================
BEGIN;
-- Scan pipeline write path
WITH new_scan AS (
    INSERT INTO public.scans (room_name, processing_status)
    VALUES ('__schema_smoke_scan__', 'uploaded')
    RETURNING id
),
ins_points AS (
    INSERT INTO public.scan_points (scan_id, timestamp_ms, x, y, z)
    SELECT id,
        0,
        0.0,
        0.0,
        0.0
    FROM new_scan
    RETURNING id
),
ins_scan_landmark AS (
    INSERT INTO public.scan_landmarks (
            scan_id,
            type,
            label,
            confidence,
            source,
            x,
            y,
            z
        )
    SELECT id,
        'unknown'::landmark_type,
        'smoke_landmark',
        0.5,
        'user'::landmark_source,
        0.0,
        0.0,
        0.0
    FROM new_scan
    RETURNING id
),
ins_detection AS (
    INSERT INTO public.ai_detections (scan_id, label, confidence)
    SELECT id,
        'smoke_detection',
        0.7
    FROM new_scan
    RETURNING id
)
SELECT (
        SELECT count(*)
        FROM new_scan
    ) AS scans_inserted,
    (
        SELECT count(*)
        FROM ins_points
    ) AS scan_points_inserted,
    (
        SELECT count(*)
        FROM ins_scan_landmark
    ) AS scan_landmarks_inserted,
    (
        SELECT count(*)
        FROM ins_detection
    ) AS ai_detections_inserted;
-- Graph + verification + hazard write path
WITH new_map AS (
    INSERT INTO public.room_maps (room_name, created_by, version)
    VALUES ('__schema_smoke_map__', gen_random_uuid(), 1)
    RETURNING id
),
start_node AS (
    INSERT INTO public.map_nodes (room_map_id, type, label, x, y, z)
    SELECT id,
        'start'::node_type,
        'start',
        0.0,
        0.0,
        0.0
    FROM new_map
    RETURNING id,
        room_map_id
),
end_node AS (
    INSERT INTO public.map_nodes (room_map_id, type, label, x, y, z)
    SELECT id,
        'end'::node_type,
        'end',
        1.0,
        0.0,
        0.0
    FROM new_map
    RETURNING id,
        room_map_id
),
ins_edge AS (
    INSERT INTO public.map_edges (
            room_map_id,
            from_node_id,
            to_node_id,
            distance,
            walkable
        )
    SELECT s.room_map_id,
        s.id,
        e.id,
        1.0,
        true
    FROM start_node s
        JOIN end_node e ON e.room_map_id = s.room_map_id
    RETURNING id
),
ins_landmark AS (
    INSERT INTO public.landmarks (
            room_map_id,
            type,
            label,
            confidence,
            source,
            x,
            y,
            z,
            status
        )
    SELECT id,
        'door'::landmark_type,
        'smoke_door',
        0.9,
        'user'::landmark_source,
        0.5,
        0.0,
        0.0,
        'pending'::verification_status
    FROM new_map
    RETURNING id
),
ins_verification AS (
    INSERT INTO public.landmark_verifications (landmark_id, verified_by, status, notes)
    SELECT id,
        gen_random_uuid(),
        'verified'::verification_status,
        'schema smoke test'
    FROM ins_landmark
    RETURNING id
),
ins_hazard AS (
    INSERT INTO public.hazard_reports (
            lat,
            lng,
            type,
            description,
            "timestamp",
            verified
        )
    VALUES (
            0.0,
            0.0,
            'obstacle',
            'schema smoke hazard',
            now(),
            false
        )
    RETURNING id
)
SELECT (
        SELECT count(*)
        FROM new_map
    ) AS maps_inserted,
    (
        SELECT count(*)
        FROM start_node
    ) + (
        SELECT count(*)
        FROM end_node
    ) AS nodes_inserted,
    (
        SELECT count(*)
        FROM ins_edge
    ) AS edges_inserted,
    (
        SELECT count(*)
        FROM ins_landmark
    ) AS landmarks_inserted,
    (
        SELECT count(*)
        FROM ins_verification
    ) AS verifications_inserted,
    (
        SELECT count(*)
        FROM ins_hazard
    ) AS hazards_inserted;
ROLLBACK;
-- If all queries return rows without errors, schema alignment is functionally valid for core writes.
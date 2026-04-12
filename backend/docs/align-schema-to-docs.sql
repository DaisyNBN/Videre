-- Align existing Supabase schema to backend/docs/postgres-schema.md
-- Run this in Supabase SQL Editor.
-- Notes:
-- 1) This migration is written to be mostly idempotent.
-- 2) It keeps extra legacy columns that are not documented, unless explicitly removed here.
-- 3) It removes user_id columns to match current backend contract.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- =========================================================
-- 1) Ensure enum types exist and include required values
-- =========================================================
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'landmark_type'
) THEN CREATE TYPE landmark_type AS ENUM (
    'door',
    'wall',
    'stair',
    'elevator',
    'obstacle',
    'exit',
    'unknown'
);
END IF;
END $$;
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'door';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'wall';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'stair';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'elevator';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'obstacle';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'exit';
ALTER TYPE landmark_type
ADD VALUE IF NOT EXISTS 'unknown';
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'landmark_source'
) THEN CREATE TYPE landmark_source AS ENUM ('user', 'gemini');
END IF;
END $$;
ALTER TYPE landmark_source
ADD VALUE IF NOT EXISTS 'user';
ALTER TYPE landmark_source
ADD VALUE IF NOT EXISTS 'gemini';
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'node_type'
) THEN CREATE TYPE node_type AS ENUM ('path', 'landmark', 'start', 'end');
END IF;
END $$;
ALTER TYPE node_type
ADD VALUE IF NOT EXISTS 'path';
ALTER TYPE node_type
ADD VALUE IF NOT EXISTS 'landmark';
ALTER TYPE node_type
ADD VALUE IF NOT EXISTS 'start';
ALTER TYPE node_type
ADD VALUE IF NOT EXISTS 'end';
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'verification_status'
) THEN CREATE TYPE verification_status AS ENUM ('pending', 'verified', 'rejected');
END IF;
END $$;
ALTER TYPE verification_status
ADD VALUE IF NOT EXISTS 'pending';
ALTER TYPE verification_status
ADD VALUE IF NOT EXISTS 'verified';
ALTER TYPE verification_status
ADD VALUE IF NOT EXISTS 'rejected';
-- =========================================================
-- 2) scans
-- =========================================================
ALTER TABLE public.scans
ALTER COLUMN room_name TYPE text,
    ALTER COLUMN processing_status TYPE text USING trim(
        both '"'
        from processing_status
    );
UPDATE public.scans
SET processing_status = 'uploaded'
WHERE processing_status IS NULL
    OR processing_status = '';
ALTER TABLE public.scans
ALTER COLUMN processing_status
SET DEFAULT 'uploaded',
    ALTER COLUMN processing_status
SET NOT NULL;
ALTER TABLE public.scans DROP COLUMN IF EXISTS user_id;
-- =========================================================
-- 3) room_maps
-- =========================================================
ALTER TABLE public.room_maps
ALTER COLUMN room_name TYPE text;
ALTER TABLE public.room_maps
ALTER COLUMN created_by TYPE uuid USING (
        CASE
            WHEN created_by::text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN created_by::uuid
            ELSE gen_random_uuid()
        END
    );
ALTER TABLE public.room_maps
ALTER COLUMN created_by
SET NOT NULL;
-- =========================================================
-- 4) map_nodes and map_edges
-- =========================================================
ALTER TABLE public.map_nodes
ALTER COLUMN type TYPE node_type USING (
        CASE
            WHEN type::text IN ('path', 'landmark', 'start', 'end') THEN type::text::node_type
            ELSE 'path'::node_type
        END
    );
ALTER TABLE public.map_nodes DROP CONSTRAINT IF EXISTS map_nodes_room_map_id_fkey;
ALTER TABLE public.map_nodes
ADD CONSTRAINT map_nodes_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id) ON DELETE CASCADE;
ALTER TABLE public.map_edges DROP CONSTRAINT IF EXISTS map_edges_room_map_id_fkey;
ALTER TABLE public.map_edges DROP CONSTRAINT IF EXISTS map_edges_from_node_id_fkey;
ALTER TABLE public.map_edges DROP CONSTRAINT IF EXISTS map_edges_to_node_id_fkey;
ALTER TABLE public.map_edges
ADD CONSTRAINT map_edges_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id) ON DELETE CASCADE;
ALTER TABLE public.map_edges
ADD CONSTRAINT map_edges_from_node_id_fkey FOREIGN KEY (from_node_id) REFERENCES public.map_nodes(id) ON DELETE CASCADE;
ALTER TABLE public.map_edges
ADD CONSTRAINT map_edges_to_node_id_fkey FOREIGN KEY (to_node_id) REFERENCES public.map_nodes(id) ON DELETE CASCADE;
WITH dedup AS (
    SELECT id,
        row_number() OVER (
            PARTITION BY room_map_id,
            from_node_id,
            to_node_id
            ORDER BY id
        ) AS rn
    FROM public.map_edges
)
DELETE FROM public.map_edges me USING dedup d
WHERE me.id = d.id
    AND d.rn > 1;
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'map_edges_room_map_from_to_key'
        AND conrelid = 'public.map_edges'::regclass
) THEN
ALTER TABLE public.map_edges
ADD CONSTRAINT map_edges_room_map_from_to_key UNIQUE (room_map_id, from_node_id, to_node_id);
END IF;
END $$;
-- =========================================================
-- 5) landmarks and landmark_verifications
-- =========================================================
ALTER TABLE public.landmarks
ALTER COLUMN type TYPE landmark_type USING (
        CASE
            WHEN type::text IN (
                'door',
                'wall',
                'stair',
                'elevator',
                'obstacle',
                'exit',
                'unknown'
            ) THEN type::text::landmark_type
            ELSE 'unknown'::landmark_type
        END
    ),
    ALTER COLUMN source TYPE landmark_source USING (
        CASE
            WHEN source::text IN ('user', 'gemini') THEN source::text::landmark_source
            ELSE 'user'::landmark_source
        END
    ),
    ALTER COLUMN status TYPE verification_status USING (
        CASE
            WHEN status::text IN ('pending', 'verified', 'rejected') THEN status::text::verification_status
            ELSE 'pending'::verification_status
        END
    );
ALTER TABLE public.landmarks
ALTER COLUMN source
SET DEFAULT 'user',
    ALTER COLUMN status
SET DEFAULT 'pending';
ALTER TABLE public.landmarks DROP CONSTRAINT IF EXISTS landmarks_room_map_id_fkey;
ALTER TABLE public.landmarks
ADD CONSTRAINT landmarks_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id) ON DELETE CASCADE;
ALTER TABLE public.landmark_verifications
ALTER COLUMN verified_by TYPE uuid USING (
        CASE
            WHEN verified_by::text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN verified_by::uuid
            ELSE gen_random_uuid()
        END
    ),
    ALTER COLUMN status TYPE verification_status USING (
        CASE
            WHEN status::text IN ('pending', 'verified', 'rejected') THEN status::text::verification_status
            ELSE 'pending'::verification_status
        END
    );
ALTER TABLE public.landmark_verifications
ALTER COLUMN verified_by
SET NOT NULL,
    ALTER COLUMN status
SET NOT NULL;
ALTER TABLE public.landmark_verifications DROP CONSTRAINT IF EXISTS landmark_verifications_landmark_id_fkey;
ALTER TABLE public.landmark_verifications
ADD CONSTRAINT landmark_verifications_landmark_id_fkey FOREIGN KEY (landmark_id) REFERENCES public.landmarks(id) ON DELETE CASCADE;
WITH dedup AS (
    SELECT id,
        row_number() OVER (
            PARTITION BY landmark_id,
            verified_by
            ORDER BY created_at DESC,
                id
        ) AS rn
    FROM public.landmark_verifications
)
DELETE FROM public.landmark_verifications lv USING dedup d
WHERE lv.id = d.id
    AND d.rn > 1;
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'landmark_verifications_landmark_verified_by_key'
        AND conrelid = 'public.landmark_verifications'::regclass
) THEN
ALTER TABLE public.landmark_verifications
ADD CONSTRAINT landmark_verifications_landmark_verified_by_key UNIQUE (landmark_id, verified_by);
END IF;
END $$;
-- =========================================================
-- 6) scan_points, scan_landmarks, ai_detections FK behavior
-- =========================================================
ALTER TABLE public.scan_points DROP CONSTRAINT IF EXISTS scan_points_scan_id_fkey;
ALTER TABLE public.scan_points
ADD CONSTRAINT scan_points_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id) ON DELETE CASCADE;
ALTER TABLE public.scan_landmarks
ALTER COLUMN type TYPE landmark_type USING (
        CASE
            WHEN type::text IN (
                'door',
                'wall',
                'stair',
                'elevator',
                'obstacle',
                'exit',
                'unknown'
            ) THEN type::text::landmark_type
            ELSE 'unknown'::landmark_type
        END
    ),
    ALTER COLUMN source TYPE landmark_source USING (
        CASE
            WHEN source::text IN ('user', 'gemini') THEN source::text::landmark_source
            ELSE 'user'::landmark_source
        END
    );
ALTER TABLE public.scan_landmarks
ALTER COLUMN type
SET DEFAULT 'unknown',
    ALTER COLUMN source
SET DEFAULT 'user';
ALTER TABLE public.scan_landmarks DROP CONSTRAINT IF EXISTS scan_landmarks_scan_id_fkey;
ALTER TABLE public.scan_landmarks
ADD CONSTRAINT scan_landmarks_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id) ON DELETE CASCADE;
ALTER TABLE public.ai_detections DROP CONSTRAINT IF EXISTS ai_detections_scan_id_fkey;
ALTER TABLE public.ai_detections
ADD CONSTRAINT ai_detections_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id) ON DELETE CASCADE;
-- =========================================================
-- 7) hazard_reports alignment
--    Target (doc):
--      id bigserial pk
--      lat,lng,type,description,timestamp,verified
--      no user_id
-- =========================================================
DO $$ BEGIN -- Rename created_at to timestamp if timestamp is missing.
IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
        AND table_name = 'hazard_reports'
        AND column_name = 'created_at'
)
AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
        AND table_name = 'hazard_reports'
        AND column_name = 'timestamp'
) THEN
ALTER TABLE public.hazard_reports
    RENAME COLUMN created_at TO "timestamp";
END IF;
END $$;
ALTER TABLE public.hazard_reports
ADD COLUMN IF NOT EXISTS "timestamp" timestamptz;
UPDATE public.hazard_reports
SET "timestamp" = COALESCE("timestamp", now());
UPDATE public.hazard_reports
SET verified = false
WHERE verified IS NULL;
ALTER TABLE public.hazard_reports
ALTER COLUMN verified
SET DEFAULT false,
    ALTER COLUMN verified
SET NOT NULL,
    ALTER COLUMN "timestamp"
SET NOT NULL;
ALTER TABLE public.hazard_reports DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.hazard_reports DROP COLUMN IF EXISTS created_at;
DO $$
DECLARE id_data_type text;
BEGIN
SELECT data_type INTO id_data_type
FROM information_schema.columns
WHERE table_schema = 'public'
    AND table_name = 'hazard_reports'
    AND column_name = 'id';
IF id_data_type IS DISTINCT
FROM 'bigint' THEN
ALTER TABLE public.hazard_reports DROP CONSTRAINT IF EXISTS hazard_reports_pkey;
ALTER TABLE public.hazard_reports
ADD COLUMN IF NOT EXISTS id_new bigint GENERATED BY DEFAULT AS IDENTITY;
ALTER TABLE public.hazard_reports DROP COLUMN IF EXISTS id;
ALTER TABLE public.hazard_reports
    RENAME COLUMN id_new TO id;
ALTER TABLE public.hazard_reports
ADD CONSTRAINT hazard_reports_pkey PRIMARY KEY (id);
END IF;
END $$;
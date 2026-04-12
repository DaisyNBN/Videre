-- Adds heading and fused spatial metadata columns used by iOS LiDAR + GPS fusion.
-- Safe to run multiple times.
ALTER TABLE IF EXISTS public.landmarks
ADD COLUMN IF NOT EXISTS heading_degrees double precision;
ALTER TABLE IF EXISTS public.scan_landmarks
ADD COLUMN IF NOT EXISTS heading_degrees double precision,
    ADD COLUMN IF NOT EXISTS latitude double precision,
    ADD COLUMN IF NOT EXISTS longitude double precision,
    ADD COLUMN IF NOT EXISTS horizontal_accuracy double precision,
    ADD COLUMN IF NOT EXISTS vertical_accuracy double precision;
ALTER TABLE IF EXISTS public.scan_points
ADD COLUMN IF NOT EXISTS latitude double precision,
    ADD COLUMN IF NOT EXISTS longitude double precision,
    ADD COLUMN IF NOT EXISTS horizontal_accuracy double precision,
    ADD COLUMN IF NOT EXISTS vertical_accuracy double precision,
    ADD COLUMN IF NOT EXISTS heading_degrees double precision,
    ADD COLUMN IF NOT EXISTS tracking_state text;
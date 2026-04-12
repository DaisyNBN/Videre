-- Backfill legacy scans JSON payloads into normalized tables.
-- Run AFTER align-schema-to-docs.sql.
-- This script is idempotent and only inserts rows not already present.
DO $$ BEGIN IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
        AND table_name = 'scans'
        AND column_name = 'points'
) THEN
INSERT INTO public.scan_points (scan_id, timestamp_ms, x, y, z) WITH parsed_points AS (
        SELECT s.id AS scan_id,
            CASE
                WHEN (p->>'timestamp') ~ '^-?[0-9]+$' THEN (p->>'timestamp')::bigint
                ELSE NULL
            END AS timestamp_ms,
            CASE
                WHEN (p->>'x') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p->>'x')::double precision
                ELSE 0
            END AS x,
            CASE
                WHEN (p->>'y') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p->>'y')::double precision
                ELSE 0
            END AS y,
            CASE
                WHEN (p->>'z') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p->>'z')::double precision
                ELSE 0
            END AS z
        FROM public.scans s
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE
                    WHEN s.points IS NULL THEN '[]'::jsonb
                    ELSE s.points::jsonb
                END
            ) p
    ),
    dedup AS (
        SELECT DISTINCT scan_id,
            timestamp_ms,
            x,
            y,
            z
        FROM parsed_points
    )
SELECT d.scan_id,
    d.timestamp_ms,
    d.x,
    d.y,
    d.z
FROM dedup d
WHERE NOT EXISTS (
        SELECT 1
        FROM public.scan_points sp
        WHERE sp.scan_id = d.scan_id
            AND COALESCE(sp.timestamp_ms, -1) = COALESCE(d.timestamp_ms, -1)
            AND sp.x = d.x
            AND sp.y = d.y
            AND sp.z = d.z
    );
RAISE NOTICE 'scan_points backfill complete.';
ELSE RAISE NOTICE 'No scans.points column found; skipping scan_points backfill.';
END IF;
END $$;
DO $$ BEGIN IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
        AND table_name = 'scans'
        AND column_name = 'landmarks'
) THEN
INSERT INTO public.scan_landmarks (
        scan_id,
        type,
        label,
        confidence,
        source,
        x,
        y,
        z
    ) WITH parsed_landmarks AS (
        SELECT s.id AS scan_id,
            CASE
                WHEN lower(COALESCE(lm->>'type', '')) IN (
                    'door',
                    'wall',
                    'stair',
                    'elevator',
                    'obstacle',
                    'exit',
                    'unknown'
                ) THEN lower(lm->>'type')::landmark_type
                ELSE 'unknown'::landmark_type
            END AS type,
            NULLIF(trim(COALESCE(lm->>'label', '')), '') AS label,
            CASE
                WHEN (lm->>'confidence') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN LEAST(
                    GREATEST((lm->>'confidence')::double precision, 0),
                    1
                )
                ELSE NULL
            END AS confidence,
            CASE
                WHEN lower(COALESCE(lm->>'source', '')) = 'gemini' THEN 'gemini'::landmark_source
                ELSE 'user'::landmark_source
            END AS source,
            CASE
                WHEN (lm->>'x') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (lm->>'x')::double precision
                ELSE 0
            END AS x,
            CASE
                WHEN (lm->>'y') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (lm->>'y')::double precision
                ELSE 0
            END AS y,
            CASE
                WHEN (lm->>'z') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (lm->>'z')::double precision
                ELSE 0
            END AS z
        FROM public.scans s
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE
                    WHEN s.landmarks IS NULL THEN '[]'::jsonb
                    ELSE s.landmarks::jsonb
                END
            ) lm
    ),
    dedup AS (
        SELECT DISTINCT scan_id,
            type,
            label,
            confidence,
            source,
            x,
            y,
            z
        FROM parsed_landmarks
    )
SELECT d.scan_id,
    d.type,
    d.label,
    d.confidence,
    d.source,
    d.x,
    d.y,
    d.z
FROM dedup d
WHERE NOT EXISTS (
        SELECT 1
        FROM public.scan_landmarks sl
        WHERE sl.scan_id = d.scan_id
            AND sl.type = d.type
            AND COALESCE(sl.label, '') = COALESCE(d.label, '')
            AND COALESCE(sl.confidence, -1) = COALESCE(d.confidence, -1)
            AND sl.source = d.source
            AND sl.x = d.x
            AND sl.y = d.y
            AND sl.z = d.z
    );
RAISE NOTICE 'scan_landmarks backfill complete.';
ELSE RAISE NOTICE 'No scans.landmarks column found; skipping scan_landmarks backfill.';
END IF;
END $$;
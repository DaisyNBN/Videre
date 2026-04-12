-- Enable RLS for map_contributions with safe, idempotent policies.
-- Run this after docs/map-contributions-schema.sql.
DO $$ BEGIN IF to_regclass('public.map_contributions') IS NULL THEN RAISE EXCEPTION 'Table public.map_contributions does not exist. Run docs/map-contributions-schema.sql first.';
END IF;
END $$;
ALTER TABLE public.map_contributions ENABLE ROW LEVEL SECURITY;
-- Authenticated users can read only their own contributions.
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
        AND tablename = 'map_contributions'
        AND policyname = 'map_contributions_select_own'
) THEN CREATE POLICY map_contributions_select_own ON public.map_contributions FOR
SELECT TO authenticated USING (created_by = auth.uid());
END IF;
END $$;
-- Authenticated users can insert only rows that belong to themselves.
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
        AND tablename = 'map_contributions'
        AND policyname = 'map_contributions_insert_own'
) THEN CREATE POLICY map_contributions_insert_own ON public.map_contributions FOR
INSERT TO authenticated WITH CHECK (created_by = auth.uid());
END IF;
END $$;
-- Optional: allow users to edit their own pending contributions only.
DO $$ BEGIN IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
        AND tablename = 'map_contributions'
        AND policyname = 'map_contributions_update_own_pending'
) THEN CREATE POLICY map_contributions_update_own_pending ON public.map_contributions FOR
UPDATE TO authenticated USING (
        created_by = auth.uid()
        AND status = 'pending'
    ) WITH CHECK (
        created_by = auth.uid()
        AND status = 'pending'
    );
END IF;
END $$;
-- Keep backend service role unrestricted for server-side workflows.
DO $$ BEGIN IF EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'service_role'
)
AND NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
        AND tablename = 'map_contributions'
        AND policyname = 'map_contributions_service_role_all'
) THEN CREATE POLICY map_contributions_service_role_all ON public.map_contributions FOR ALL TO service_role USING (true) WITH CHECK (true);
END IF;
END $$;
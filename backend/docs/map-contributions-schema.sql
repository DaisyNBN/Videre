-- Create storage for map contributions and review status.
-- Run this in Supabase SQL Editor before using /api/maps/:id/contributions routes.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.map_contributions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    map_id uuid NOT NULL REFERENCES public.room_maps(id) ON DELETE CASCADE,
    contribution_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
    created_by uuid NOT NULL,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_map_contributions_map_id ON public.map_contributions (map_id);
CREATE INDEX IF NOT EXISTS idx_map_contributions_status ON public.map_contributions (status);
CREATE INDEX IF NOT EXISTS idx_map_contributions_created_at ON public.map_contributions (created_at DESC);
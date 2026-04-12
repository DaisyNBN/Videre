-- Migration: add optional GPS anchor columns to persisted map landmarks.
-- Exit landmarks can use these fields to store an approximate outdoor/indoor
-- entry point so future devices can discover known exits for a room map.

ALTER TABLE public.landmarks
  ADD COLUMN IF NOT EXISTS anchor_lat double precision,
  ADD COLUMN IF NOT EXISTS anchor_lng double precision;

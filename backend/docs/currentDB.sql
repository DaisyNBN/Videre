-- WARNING: This schema is for context only and is not meant to be run.
-- Table order and constraints may not be valid for execution.
CREATE TABLE public.ai_detections (
    id bigint NOT NULL DEFAULT nextval('ai_detections_id_seq'::regclass),
    scan_id uuid NOT NULL,
    label text NOT NULL,
    confidence double precision NOT NULL CHECK (
        confidence >= 0::double precision
        AND confidence <= 1::double precision
    ),
    bbox_x double precision,
    bbox_y double precision,
    bbox_width double precision,
    bbox_height double precision,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT ai_detections_pkey PRIMARY KEY (id),
    CONSTRAINT ai_detections_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id)
);
CREATE TABLE public.hazard_reports (
    lat double precision NOT NULL,
    lng double precision NOT NULL,
    type text NOT NULL,
    description text NOT NULL,
    verified boolean NOT NULL DEFAULT false,
    timestamp timestamp with time zone NOT NULL DEFAULT now(),
    id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    CONSTRAINT hazard_reports_pkey PRIMARY KEY (id)
);
CREATE TABLE public.landmark_verifications (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    landmark_id uuid NOT NULL,
    verified_by uuid NOT NULL,
    status USER - DEFINED NOT NULL,
    notes text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT landmark_verifications_pkey PRIMARY KEY (id),
    CONSTRAINT landmark_verifications_landmark_id_fkey FOREIGN KEY (landmark_id) REFERENCES public.landmarks(id)
);
CREATE TABLE public.landmarks (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    room_map_id uuid NOT NULL,
    type USER - DEFINED NOT NULL,
    label text,
    confidence double precision CHECK (
        confidence >= 0::double precision
        AND confidence <= 1::double precision
    ),
    source USER - DEFINED NOT NULL DEFAULT 'user'::landmark_source,
    x double precision NOT NULL,
    y double precision NOT NULL,
    z double precision NOT NULL,
    status USER - DEFINED NOT NULL DEFAULT 'pending'::verification_status,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT landmarks_pkey PRIMARY KEY (id),
    CONSTRAINT landmarks_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id)
);
CREATE TABLE public.map_edges (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    room_map_id uuid NOT NULL,
    from_node_id uuid NOT NULL,
    to_node_id uuid NOT NULL,
    distance double precision NOT NULL CHECK (distance >= 0::double precision),
    walkable boolean NOT NULL DEFAULT true,
    CONSTRAINT map_edges_pkey PRIMARY KEY (id),
    CONSTRAINT map_edges_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id),
    CONSTRAINT map_edges_from_node_id_fkey FOREIGN KEY (from_node_id) REFERENCES public.map_nodes(id),
    CONSTRAINT map_edges_to_node_id_fkey FOREIGN KEY (to_node_id) REFERENCES public.map_nodes(id)
);
CREATE TABLE public.map_nodes (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    room_map_id uuid NOT NULL,
    type USER - DEFINED NOT NULL,
    label text,
    x double precision NOT NULL,
    y double precision NOT NULL,
    z double precision NOT NULL,
    CONSTRAINT map_nodes_pkey PRIMARY KEY (id),
    CONSTRAINT map_nodes_room_map_id_fkey FOREIGN KEY (room_map_id) REFERENCES public.room_maps(id)
);
CREATE TABLE public.room_maps (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    room_name text NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    version integer NOT NULL DEFAULT 1,
    CONSTRAINT room_maps_pkey PRIMARY KEY (id)
);
CREATE TABLE public.route_checkpoints (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    route_id text NOT NULL,
    order_num integer NOT NULL,
    lat double precision NOT NULL,
    lng double precision NOT NULL,
    label text NOT NULL,
    instruction text NOT NULL,
    CONSTRAINT route_checkpoints_pkey PRIMARY KEY (id)
);
CREATE TABLE public.scan_landmarks (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    scan_id uuid NOT NULL,
    type USER - DEFINED NOT NULL DEFAULT 'unknown'::landmark_type,
    label text,
    confidence double precision CHECK (
        confidence >= 0::double precision
        AND confidence <= 1::double precision
    ),
    source USER - DEFINED NOT NULL DEFAULT 'user'::landmark_source,
    x double precision NOT NULL,
    y double precision NOT NULL,
    z double precision NOT NULL,
    CONSTRAINT scan_landmarks_pkey PRIMARY KEY (id),
    CONSTRAINT scan_landmarks_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id)
);
CREATE TABLE public.scan_points (
    id bigint NOT NULL DEFAULT nextval('scan_points_id_seq'::regclass),
    scan_id uuid NOT NULL,
    timestamp_ms bigint,
    x double precision NOT NULL,
    y double precision NOT NULL,
    z double precision NOT NULL,
    CONSTRAINT scan_points_pkey PRIMARY KEY (id),
    CONSTRAINT scan_points_scan_id_fkey FOREIGN KEY (scan_id) REFERENCES public.scans(id)
);
CREATE TABLE public.scans (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    room_name text NOT NULL,
    processing_status text NOT NULL DEFAULT 'uploaded'::text,
    CONSTRAINT scans_pkey PRIMARY KEY (id)
);
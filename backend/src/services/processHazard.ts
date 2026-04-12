import { HazardReport } from "../types";
import { filterWithinRadius } from "../utils/distance";
import { supabase } from "./supabase";

export async function insertHazard(
  report: HazardReport
): Promise<{ success: boolean; error?: string }> {
  const { error } = await supabase.from("hazard_reports").insert({
    lat: report.lat,
    lng: report.lng,
    type: report.type,
    description: report.description,
  });

  if (error) {
    console.error("Supabase insert error:", error.message);
    return { success: false, error: error.message };
  }

  return { success: true };
}

export async function getNearbyHazards(
  lat: number,
  lng: number,
  radiusMeters: number = 100
): Promise<HazardReport[]> {
  const buffer = radiusMeters / 111000;

  const { data, error } = await supabase
    .from("hazard_reports")
    .select("*")
    .gte("lat", lat - buffer)
    .lte("lat", lat + buffer)
    .gte("lng", lng - buffer)
    .lte("lng", lng + buffer);

  if (error) {
    console.error("Supabase query error:", error.message);
    return [];
  }

  if (!data || data.length === 0) return [];

  return filterWithinRadius(data as HazardReport[], lat, lng, radiusMeters);
}

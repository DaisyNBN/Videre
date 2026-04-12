import { NavRequest, NavResponse } from "../types";
import { supabase } from "./supabase";
import { haversineMeters } from "../utils/distance";
import { getGeminiNavResponse } from "./gemini";
import { getFallbackResponse } from "../fallback";
import { getNearbyHazards } from "./processHazard";

export async function getNavigationInstruction(
  request: NavRequest
): Promise<NavResponse> {
  const { data: checkpoints } = await supabase
    .from("route_checkpoints")
    .select("*")
    .eq("route_id", request.route_id);

  let nearest: { label: string; distance: number } | undefined;

  if (checkpoints && checkpoints.length > 0) {
    let minDist = Infinity;
    for (const cp of checkpoints) {
      const dist = haversineMeters(
        request.location.lat,
        request.location.lng,
        cp.lat,
        cp.lng
      );
      if (dist < minDist) {
        minDist = dist;
        nearest = { label: cp.label, distance: Math.round(dist) };
      }
    }
  }

  let response: NavResponse;
  try {
    response = await getGeminiNavResponse(request, nearest);
  } catch (err) {
    console.error("Gemini failed in pipeline:", err);
    response = getFallbackResponse(request.obstacles, nearest);
  }

  const hazards = await getNearbyHazards(
    request.location.lat,
    request.location.lng,
    50
  );

  if (hazards.length > 0 && response.urgency === "low") {
    response.urgency = "medium";
    response.haptic_pattern = "double_tap";
  }

  return response;
}

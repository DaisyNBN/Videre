import { supabase } from "./supabase";
import { ScanUploadRequest, ScanPoint, Landmark } from "../types";
import { buildAndSaveGraph } from "./buildGraph";

export async function createScan(
  request: ScanUploadRequest
): Promise<{ success: boolean; scanId?: string; mapId?: string; error?: string }> {
  const { data: scan, error: scanError } = await supabase
    .from("scans")
    .insert({
      user_id: request.userId,
      room_name: request.roomName,
      processing_status: "uploaded",
    })
    .select("id")
    .single();

  if (scanError || !scan) {
    console.error("Scan insert error:", scanError?.message);
    return { success: false, error: scanError?.message ?? "Failed to create scan" };
  }

  const scanId = scan.id;

  if (request.points.length > 0) {
    const pointRows = request.points.map((p: ScanPoint) => ({
      scan_id: scanId,
      x: p.x,
      y: p.y,
      z: p.z,
      timestamp_ms: p.timestamp ?? null,
    }));

    const { error: pointsError } = await supabase
      .from("scan_points")
      .insert(pointRows);

    if (pointsError) {
      console.error("Scan points insert error:", pointsError.message);
      return { success: false, scanId, error: pointsError.message };
    }
  }

  if (request.landmarks.length > 0) {
    const landmarkRows = request.landmarks.map((lm: Landmark) => ({
      scan_id: scanId,
      type: lm.type,
      label: lm.label ?? null,
      confidence: lm.confidence ?? null,
      source: lm.source ?? "user",
      x: lm.x,
      y: lm.y,
      z: lm.z,
    }));

    const { error: landmarksError } = await supabase
      .from("scan_landmarks")
      .insert(landmarkRows);

    if (landmarksError) {
      console.error("Scan landmarks insert error:", landmarksError.message);
      return { success: false, scanId, error: landmarksError.message };
    }
  }

  const graphResult = await buildAndSaveGraph(
    scanId,
    request.userId,
    request.roomName,
    request.points,
    request.landmarks
  );

  await supabase
    .from("scans")
    .update({ processing_status: graphResult.success ? "processed" : "graph_failed" })
    .eq("id", scanId);

  return { success: true, scanId, mapId: graphResult.mapId };
}

export async function getScanById(scanId: string): Promise<{
  scan: any;
  points: any[];
  landmarks: any[];
} | null> {
  const { data: scan, error: scanError } = await supabase
    .from("scans")
    .select("*")
    .eq("id", scanId)
    .single();

  if (scanError || !scan) return null;

  const { data: points } = await supabase
    .from("scan_points")
    .select("*")
    .eq("scan_id", scanId);

  const { data: landmarks } = await supabase
    .from("scan_landmarks")
    .select("*")
    .eq("scan_id", scanId);

  return {
    scan,
    points: points ?? [],
    landmarks: landmarks ?? [],
  };
}

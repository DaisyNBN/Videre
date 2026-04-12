import { supabase } from "./supabase";
import { AIObjectDetection } from "../types";

export async function saveDetections(
  scanId: string,
  detections: AIObjectDetection[]
): Promise<{ success: boolean; count: number; error?: string }> {
  if (detections.length === 0) {
    return { success: true, count: 0 };
  }

  const rows = detections.map((d) => ({
    scan_id: scanId,
    label: d.label,
    confidence: d.confidence,
    bbox_x: d.boundingBox?.x ?? null,
    bbox_y: d.boundingBox?.y ?? null,
    bbox_width: d.boundingBox?.width ?? null,
    bbox_height: d.boundingBox?.height ?? null,
  }));

  const { error } = await supabase.from("ai_detections").insert(rows);

  if (error) {
    console.error("AI detection insert error:", error.message);
    return { success: false, count: 0, error: error.message };
  }

  return { success: true, count: detections.length };
}

export async function getDetectionsForScan(
  scanId: string
): Promise<AIObjectDetection[]> {
  const { data, error } = await supabase
    .from("ai_detections")
    .select("*")
    .eq("scan_id", scanId);

  if (error || !data) return [];

  return data.map((row) => ({
    label: row.label,
    confidence: row.confidence,
    boundingBox: row.bbox_x != null
      ? {
          x: row.bbox_x,
          y: row.bbox_y,
          width: row.bbox_width,
          height: row.bbox_height,
        }
      : undefined,
  }));
}

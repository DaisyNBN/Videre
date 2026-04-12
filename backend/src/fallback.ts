import { Obstacle, NavResponse } from "./types";

export function getFallbackResponse(
  obstacles: Obstacle[],
  checkpoint?: { label: string; distance: number }
): NavResponse {
  const blocking = obstacles.find(
    (o) => o.distance_estimate === "near" && o.position === "center"
  );

  if (blocking) {
    return {
      instruction: `${blocking.label} ahead. Stop. Step right.`,
      urgency: "high",
      haptic_pattern: "continuous",
      next_checkpoint: checkpoint?.label ?? null,
      distance_to_next_m: checkpoint?.distance ?? null,
      fallback_used: true,
    };
  }

  const nearby = obstacles.find((o) => o.distance_estimate === "near");
  if (nearby) {
    const avoidDir = nearby.position === "left" ? "right" : "left";
    return {
      instruction: `${nearby.label} on your ${nearby.position}. Keep ${avoidDir}.`,
      urgency: "medium",
      haptic_pattern: "double_tap",
      next_checkpoint: checkpoint?.label ?? null,
      distance_to_next_m: checkpoint?.distance ?? null,
      fallback_used: true,
    };
  }

  return {
    instruction: checkpoint
      ? `Continue straight. ${checkpoint.label} ahead.`
      : "Continue straight. Path is clear.",
    urgency: "low",
    haptic_pattern: "single_tap",
    next_checkpoint: checkpoint?.label ?? null,
    distance_to_next_m: checkpoint?.distance ?? null,
    fallback_used: true,
  };
}

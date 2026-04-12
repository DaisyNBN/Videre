import { Request, Response } from "express";
import { ApiResponse } from "../src/ApiResponse";
import { validateBody, validateQuery } from "../src/middleware/validate";
import { nearbyHazardsQuerySchema, reportHazardBodySchema } from "../src/schemas/hazards";
import logger from "../src/services/logger";
import { insertHazard, getNearbyHazards } from "../src/services/processHazard";

const router = require("express").Router();

router.post("/", validateBody(reportHazardBodySchema), async (req: Request, res: Response) => {
  try {
    const { lat, lng, type, description } = req.body;

    const result = await insertHazard({
      lat,
      lng,
      type,
      description,
      timestamp: new Date().toISOString(),
      verified: false,
    });

    if (result.success) {
      res.status(201).json(new ApiResponse(true, "Hazard reported"));
    } else {
      res.status(500).json(new ApiResponse(false, result.error ?? "Failed to report hazard"));
    }
  } catch (err) {
    logger.error("Hazard report error: %o", err);
    res.status(500).json(new ApiResponse(false, "Internal server error"));
  }
});

router.get("/nearby", validateQuery(nearbyHazardsQuerySchema), async (req: Request, res: Response) => {
  try {
    const { lat, lng, radius } = nearbyHazardsQuerySchema.parse(req.query);

    const hazards = await getNearbyHazards(lat, lng, radius);
    res.json(
      new ApiResponse(true, "Nearby hazards fetched", {
        hazards,
        count: hazards.length,
      }),
    );
  } catch (err) {
    logger.error("Nearby hazards error: %o", err);
    res.status(500).json(new ApiResponse(false, "Internal server error"));
  }
});

export default router;
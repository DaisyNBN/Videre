import { Request, Response } from "express";
import { insertHazard, getNearbyHazards } from "../src/services/processHazard";

const router = require("express").Router();

router.post("/", async (req: Request, res: Response) => {
  try {
    const { user_id, lat, lng, type, description } = req.body;

    if (!lat || !lng || !type) {
      res.status(400).json({ error: "Missing lat, lng, or type" });
      return;
    }

    const result = await insertHazard({
      user_id,
      lat,
      lng,
      type,
      description,
      timestamp: new Date().toISOString(),
      verified: false,
    });

    if (result.success) {
      res.status(201).json({ message: "Hazard reported" });
    } else {
      res.status(500).json({ error: result.error });
    }
  } catch (err) {
    console.error("Hazard report error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.get("/nearby", async (req: Request, res: Response) => {
  try {
    const lat = parseFloat(req.query.lat as string);
    const lng = parseFloat(req.query.lng as string);
    const radius = parseFloat(req.query.radius as string) || 100;

    if (isNaN(lat) || isNaN(lng)) {
      res.status(400).json({ error: "Missing or invalid lat/lng" });
      return;
    }

    const hazards = await getNearbyHazards(lat, lng, radius);
    res.json({ hazards, count: hazards.length });
  } catch (err) {
    console.error("Nearby hazards error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;

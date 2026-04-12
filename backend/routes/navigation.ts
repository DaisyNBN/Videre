import { Request, Response } from "express";
import { getNavigationInstruction } from "../src/services/processNavigation";

const router = require("express").Router();

router.post("/", async (req: Request, res: Response) => {
  try {
    const { user_id, route_id, location, heading_degrees, obstacles, speed } =
      req.body;

    if (!location || !obstacles) {
      res.status(400).json({ error: "Missing location or obstacles" });
      return;
    }

    const response = await getNavigationInstruction({
      user_id,
      route_id,
      location,
      heading_degrees,
      obstacles,
      speed,
    });

    res.json(response);
  } catch (err) {
    console.error("Navigation error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;

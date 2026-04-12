import { Request, Response } from "express";
import { supabase } from "../src/services/supabase";

const router = require("express").Router();

router.get("/:id", async (req: Request, res: Response) => {
  try {
    const mapId = req.params.id as string;

    const { data: roomMap, error: mapError } = await supabase
      .from("room_maps")
      .select("*")
      .eq("id", mapId)
      .single();

    if (mapError || !roomMap) {
      res.status(404).json({ error: "Map not found" });
      return;
    }

    const { data: nodes } = await supabase
      .from("map_nodes")
      .select("*")
      .eq("room_map_id", mapId);

    const { data: edges } = await supabase
      .from("map_edges")
      .select("*")
      .eq("room_map_id", mapId);

    res.json({
      ...roomMap,
      nodes: nodes ?? [],
      edges: edges ?? [],
    });
  } catch (err) {
    console.error("Map fetch error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;

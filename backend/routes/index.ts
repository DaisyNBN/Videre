import { Request, Response } from "express";

const router = require('express').Router();

// Import route handlers

// Define routes

// health check
router.get('/health', (req: Request, res: Response) => {
    res.sendStatus(200);
});

module.exports = router;
"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const router = require('express').Router();
// Import route handlers
const scans_1 = __importDefault(require("./scans"));
// Define routes
router.use('/scans', scans_1.default);
// health check
router.get('/health', (req, res) => {
    res.sendStatus(200);
});
module.exports = router;

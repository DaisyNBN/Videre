"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const cors_1 = __importDefault(require("cors"));
require("dotenv/config");
const index_1 = __importDefault(require("./routes/index"));
const ApiResponse_1 = require("./src/ApiResponse");
const errorHandler_1 = require("./src/middleware/errorHandler");
const app = (0, express_1.default)();
const PORT = process.env.PORT || 3000;
const allowedOrigins = [process.env.FRONTEND_URL || 'https://washu26.kurosan.dev'];
app.use((0, cors_1.default)({
    origin: (origin, callback) => {
        if (!origin || allowedOrigins.includes(origin)) {
            callback(null, true);
        }
        else {
            callback(new Error('Not allowed by CORS'));
        }
    },
    credentials: true,
}));
app.use('/_health', (req, res) => {
    res.status(200).json({ status: 'healthy' });
});
app.use(express_1.default.json({ limit: '10mb' }));
app.use(express_1.default.urlencoded({ extended: true, limit: '10mb' }));
app.use('/api', index_1.default);
app.use((req, res) => {
    if (req.path.startsWith('/api')) {
        res.status(404).json(new ApiResponse_1.ApiResponse(false, 'Route not found'));
    }
});
app.use(errorHandler_1.errorHandler);
app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});

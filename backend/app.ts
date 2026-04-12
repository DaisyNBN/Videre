import express from "express";
import cors from "cors";
import "dotenv/config";
import routes from "./routes/index";
import { ApiResponse } from "./src/ApiResponse";
import { errorHandler } from "./src/middleware/errorHandler";

const app = express();
const PORT = process.env.PORT || 3000;
const allowedOrigins = [process.env.FRONTEND_URL || 'https://washu26.kurosan.dev'];
app.use(cors({
    origin: (origin, callback) => {
        if (!origin || allowedOrigins.includes(origin)) {
            callback(null, true);
        } else {
            callback(new Error('Not allowed by CORS'));
        }
    },
    credentials: true,
}));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

app.use('/api', routes);

app.use('/api', (_req, res) => {
    res.status(404).json(new ApiResponse(false, 'Route not found'));
});

app.use(errorHandler);

app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});

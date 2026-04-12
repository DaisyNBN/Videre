import express from "express";
import cors from "cors";
require("dotenv").config();

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

app.use('/api', require('./routes/index'));

app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});

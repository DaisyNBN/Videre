# Dockerfile for Videre Backend
# Generated for containerization with Kubernetes deployment

FROM node:20-alpine

WORKDIR /app

# Install dependencies
COPY backend/package*.json ./
RUN npm ci --only=production

# Copy application code
COPY backend/dist ./dist
COPY backend/src ./src
COPY backend/routes ./routes

# Create non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
USER nodejs

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/api', (r) => {if (r.statusCode !== 404) throw new Error(r.statusCode)})"

EXPOSE 3000

CMD ["node", "dist/app.js"]

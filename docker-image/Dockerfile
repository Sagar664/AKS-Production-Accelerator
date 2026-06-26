# Sample multi-stage Dockerfile for a containerized Node.js application
# Replace the build steps and runtime command with your application specifics.

# Stage 1: Build
FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies based on package.json and package-lock.json
COPY package*.json ./
RUN npm ci --production=false

# Copy app source and build artifacts
COPY . ./
RUN npm run build

# Stage 2: Production runtime
FROM node:20-alpine AS runtime
WORKDIR /app

# Copy only production dependencies and build output
COPY package*.json ./
RUN npm ci --production=true
COPY --from=build /app/dist ./dist

# Expose the application port
EXPOSE 3000
ENV NODE_ENV=production

# Default command to run the application
CMD [ node, dist/index.js]

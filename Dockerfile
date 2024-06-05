FROM node:18-alpine

ENV PORT 3000
ENV NODE_ENV production
ENV KEY_VAULT_NAME nathan-wk4-bootcamp
WORKDIR /usr/src/app

# Copy package.json and package-lock.json first to leverage Docker cache
COPY package*.json ./

RUN npm install

# Copy the rest of the source files into the image.
COPY . .

# Expose the port that the application listens on.
EXPOSE 3000

# Run the application.
CMD ["node", "index.js"]

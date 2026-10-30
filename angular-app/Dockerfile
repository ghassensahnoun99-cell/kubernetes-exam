# Stage 1 : compilation Angular avec Node.js
FROM node:16-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install --force
COPY . .
RUN npm run build --force

# Stage 2 : service des fichiers statiques avec Nginx
FROM nginx:1.17.1-alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist/angular-app /usr/share/nginx/html
EXPOSE 80

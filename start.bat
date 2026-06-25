@echo off
echo Iniciando jekyll-theme-chirpy...
docker compose down
docker volume rm jekyll-theme-chirpy_jekyll_gems jekyll-theme-chirpy_node_modules
docker compose build --no-cache
docker compose up -d

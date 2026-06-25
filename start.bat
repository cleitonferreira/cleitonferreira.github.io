@echo off
echo Iniciando jekyll-theme-chirpy...
docker compose down -v
docker compose build --no-cache
docker compose up -d

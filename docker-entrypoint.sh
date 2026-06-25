#!/bin/sh
set -e

echo "Building JS assets..."
npm run build:js

echo "Starting Jekyll..."
exec bundle exec jekyll serve --host 0.0.0.0 --livereload --force_polling

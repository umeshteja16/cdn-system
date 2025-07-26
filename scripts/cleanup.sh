set -e

echo "🧹 Cleaning up CDN system..."

# Stop and remove containers
docker-compose down -v

# Remove generated files
rm -f .env

# Remove uploaded files (optional)
read -p "Remove uploaded files? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf uploads/*
    rm -rf cache/*
    rm -rf logs/*
fi

echo "✅ Cleanup complete!"
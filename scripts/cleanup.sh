#!/bin/bash
# scripts/cleanup.sh
set -e

echo "🧹 CDN System Cleanup Script"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to ask for confirmation
confirm() {
    local message=$1
    local default=${2:-"N"}
    
    if [ "$default" = "Y" ]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi
    
    echo -n -e "${YELLOW}$message $prompt: ${NC}"
    read -r response
    
    if [ "$default" = "Y" ]; then
        case "$response" in
            [nN][oO]|[nN]) return 1 ;;
            *) return 0 ;;
        esac
    else
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    print_warning "Docker is not running. Limited cleanup possible."
    DOCKER_AVAILABLE=false
else
    DOCKER_AVAILABLE=true
fi

print_info "Starting cleanup process..."

# 1. Stop and remove containers
if [ "$DOCKER_AVAILABLE" = true ]; then
    print_info "Stopping Docker containers..."
    if docker-compose ps -q | grep -q .; then
        docker-compose down --remove-orphans
        print_status "Containers stopped and removed"
    else
        print_info "No running containers found"
    fi
fi

# 2. Remove volumes (with confirmation)
if [ "$DOCKER_AVAILABLE" = true ]; then
    if confirm "🗑️  Remove all data volumes? This will delete all uploaded files, databases, and cached data" "N"; then
        docker-compose down -v 2>/dev/null || true
        print_status "Data volumes removed"
    else
        print_info "Data volumes preserved"
    fi
fi

# 3. Remove Docker images (with confirmation)
if [ "$DOCKER_AVAILABLE" = true ]; then
    if confirm "🗑️  Remove built Docker images? This will require rebuilding on next deployment" "N"; then
        # Get image names from docker-compose
        images=$(docker-compose config --services | xargs -I {} echo "cdn-system_{}")
        
        for image in $images; do
            if docker images | grep -q "$image" 2>/dev/null; then
                docker rmi "$image" 2>/dev/null || true
                print_info "Removed image: $image"
            fi
        done
        
        # Also remove images with project name prefix
        docker images --format "table {{.Repository}}:{{.Tag}}" | grep "cdn-" | awk '{print $1}' | xargs -r docker rmi 2>/dev/null || true
        
        print_status "Docker images removed"
    else
        print_info "Docker images preserved"
    fi
fi

# 4. Clean up generated files
print_info "Cleaning up generated files and directories..."

# Remove environment file
if [ -f .env ]; then
    if confirm "🗑️  Remove .env configuration file?" "Y"; then
        rm -f .env
        print_status ".env file removed"
    else
        print_info ".env file preserved"
    fi
fi

# Clean uploads directory
if [ -d "origin-server/uploads" ]; then
    if confirm "🗑️  Clear uploads directory?" "Y"; then
        rm -rf origin-server/uploads/*
        print_status "Uploads directory cleared"
    else
        print_info "Uploads directory preserved"
    fi
fi

# Remove SSL certificates (development ones)
if [ -d "nginx/ssl" ]; then
    if confirm "🗑️  Remove development SSL certificates?" "Y"; then
        rm -f nginx/ssl/cdn.key nginx/ssl/cdn.crt
        print_status "Development SSL certificates removed"
    else
        print_info "SSL certificates preserved"
    fi
fi

# Remove log files
if [ -d "logs" ]; then
    rm -rf logs/*
    print_status "Log files cleared"
fi

# Remove test artifacts
print_info "Removing test artifacts..."
rm -f test-results.txt load-test-results.txt .test-filename
rm -f test-file.txt test-file.html test-file.png
print_status "Test artifacts removed"

# Remove temporary files
rm -f *.tmp *.log nohup.out
print_status "Temporary files removed"

# 5. Docker system cleanup (with confirmation)
if [ "$DOCKER_AVAILABLE" = true ]; then
    if confirm "🗑️  Run Docker system prune? This removes unused containers, networks, and images" "N"; then
        print_info "Running Docker system prune..."
        docker system prune -f
        print_status "Docker system pruned"
    else
        print_info "Docker system prune skipped"
    fi
    
    # Clean up dangling volumes
    if confirm "🗑️  Remove dangling Docker volumes?" "N"; then
        docker volume prune -f
        print_status "Dangling volumes removed"
    fi
    
    # Clean up unused networks
    if confirm "🗑️  Remove unused Docker networks?" "Y"; then
        docker network prune -f
        print_status "Unused networks removed"
    fi
fi

# 6. Reset directory permissions
print_info "Resetting directory permissions..."
if [ -d "origin-server/uploads" ]; then
    chmod 755 origin-server/uploads
fi
if [ -d "nginx/ssl" ]; then
    chmod 755 nginx/ssl
fi
print_status "Permissions reset"

# 7. Summary of what was cleaned
echo ""
print_info "Cleanup Summary:"
echo "  ✓ Docker containers stopped and removed"
echo "  ✓ Generated files cleaned up"
echo "  ✓ Test artifacts removed"
echo "  ✓ Temporary files cleared"
echo "  ✓ Directory permissions reset"

# 8. Show disk space freed (if possible)
if command -v du >/dev/null 2>&1; then
    current_size=$(du -sh . 2>/dev/null | cut -f1)
    print_info "Current directory size: $current_size"
fi

echo ""
print_status "🎉 Cleanup completed!"

# 9. Next steps information
echo ""
print_info "Next Steps:"
echo "  📁 Project structure preserved"
echo "  🔧 To redeploy: ./scripts/setup.sh && ./scripts/deploy.sh"
echo "  🗑️  To remove project completely: cd .. && rm -rf cdn-system/"
echo ""

# 10. Advanced cleanup options
if confirm "🔧 Show advanced cleanup options?" "N"; then
    echo ""
    print_info "Advanced Cleanup Commands:"
    echo ""
    echo "Remove ALL Docker containers:"
    echo "  docker rm -f \$(docker ps -aq)"
    echo ""
    echo "Remove ALL Docker images:"
    echo "  docker rmi -f \$(docker images -aq)"
    echo ""
    echo "Remove ALL Docker volumes:"
    echo "  docker volume rm \$(docker volume ls -q)"
    echo ""
    echo "Complete Docker reset:"
    echo "  docker system prune -a --volumes"
    echo ""
    print_warning "⚠️  Use these commands carefully - they affect ALL Docker resources!"
fi

# 11. Check for any remaining CDN processes
print_info "Checking for any remaining processes..."
if pgrep -f "cdn-" >/dev/null 2>&1; then
    print_warning "Found running CDN-related processes:"
    pgrep -f "cdn-" | xargs ps -p 2>/dev/null || true
    echo ""
    if confirm "Kill remaining CDN processes?" "N"; then
        pkill -f "cdn-" 2>/dev/null || true
        print_status "Remaining processes terminated"
    fi
else
    print_status "No remaining CDN processes found"
fi

echo ""
print_status "🧹 All cleanup operations completed!"

# 12. Final confirmation for complete removal
echo ""
if confirm "🗑️  DANGER: Remove the entire cdn-system directory? This cannot be undone!" "N"; then
    print_warning "Removing entire project directory in 5 seconds... Press Ctrl+C to cancel!"
    sleep 5
    cd ..
    rm -rf cdn-system/
    print_status "Project directory completely removed"
    echo "👋 CDN System has been completely removed from your system."
else
    print_info "Project directory preserved"
    echo ""
    print_info "🔄 To restart the CDN system:"
    echo "   ./scripts/setup.sh"
    echo "   ./scripts/deploy.sh"
fi
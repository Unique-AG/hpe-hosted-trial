#!/bin/bash

# This script updates the versions in app.yaml files based on the versions.yaml file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.yaml"
APPS_DIR="$SCRIPT_DIR/2-applications/apps"
SERVICES_DIR="$SCRIPT_DIR/2-applications/services"

# Function to update version in app.yaml file
update_version() {
  local app_dir="$1"
  local app_name="$2"
  local version="$3"
  local app_yaml="$app_dir/app.yaml"
  
  if [ ! -f "$app_yaml" ]; then
    echo "WARNING: $app_yaml not found, skipping..."
    return
  fi
  
  echo "Updating $app_yaml with version $version"
  
  # Use sed to replace the version in the file
  # Match both web apps and backend services patterns
  # For web apps (image directly under tag)
  sed -i.bak -E "s|([ ]+tag:[ ]+)\"[^\"]+\"|\1\"$version\"|g" "$app_yaml"
  
  rm -f "${app_yaml}.bak"
}

echo "Updating app and service versions based on $VERSIONS_FILE"

# Web Apps
echo "Processing web apps..."
web_apps=("admin" "chat" "knowledge-upload" "theme")
for app in "${web_apps[@]}"; do
  # Extract version from versions.yaml
  version=$(grep -A1 "^[ ]*$app:" "$VERSIONS_FILE" | grep -v "$app:" | sed -E 's/.*- ([^ ]+).*/\1/')
  
  if [ -n "$version" ]; then
    update_version "$APPS_DIR/$app" "$app" "$version"
  else
    echo "WARNING: Version for web app '$app' not found in versions.yaml"
  fi
done

# Backend Services
echo "Processing backend services..."
# List of service directories to process
service_dirs="app-repo ingestion ingestion-worker scope-management chat theme webhook-scheduler webhook-worker assistants-core assistants-reranker"

for service_dir in $service_dirs; do
  # Map service directory to image name in versions.yaml
  case "$service_dir" in
    "app-repo")
      image_name="app-repository"
      ;;
    "scope-management")
      image_name="node-scope-management"
      ;;
    "chat")
      image_name="node-chat"
      ;;
    "theme")
      image_name="node-theme"
      ;;
    *)
      # For most services, the name is the same
      image_name="$service_dir"
      ;;
  esac
  
  # Extract version from versions.yaml
  version=$(grep -A1 "^[ ]*$image_name:" "$VERSIONS_FILE" | grep -v "$image_name:" | sed -E 's/.*- ([^ ]+).*/\1/')
  
  if [ -n "$version" ]; then
    update_version "$SERVICES_DIR/$service_dir" "$image_name" "$version"
  else
    echo "WARNING: Version for service '$service_dir' ($image_name) not found in versions.yaml"
  fi
done

echo "Version update completed!" 
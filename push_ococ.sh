#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: push_ococ.sh \"commit message\""
    exit 1
fi

MSG="$1"

PROJECTS=(
    "/var/www/myococ.connexus.team"
    "/var/www/ococsite.connexus.team"
    "/var/www/api.connexus.team"
)

for PROJECT in "${PROJECTS[@]}"; do
    NAME=$(basename "$PROJECT")
    echo "========================================="
    echo "Pushing: $NAME"
    echo "========================================="

    cd "$PROJECT" || { echo "ERROR: Could not cd into $PROJECT"; continue; }

    git add -A
    git commit -m "$MSG"
    git push

    if [ $? -eq 0 ]; then
        echo "$NAME pushed successfully."
    else
        echo "ERROR: Failed to push $NAME."
    fi

    echo ""
done

echo "Done."

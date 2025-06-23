#!/bin/bash

# Remove all containers if any exist
if [ "$(sudo docker ps -a -q)" ]; then
    echo "Removing containers..."
    sudo docker rm -f $(sudo docker ps -a -q)
else
    echo "No containers to remove"
fi

# Remove all images if any exist
if [ "$(sudo docker images -a -q)" ]; then
    echo "Removing images..."
    sudo docker rmi -f $(sudo docker images -a -q)
else
    echo "No images to remove"
fi

# Remove all volumes if any exist
if [ "$(sudo docker volume ls -q)" ]; then
    echo "Removing volumes..."
    sudo docker volume rm -f $(sudo docker volume ls -q)
else
    echo "No volumes to remove"
fi

# Clean up system
echo "Pruning system..."
sudo docker system prune -f
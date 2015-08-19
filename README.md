# Rocker

A utility manage Dockerfile, image, container and volume.

# Usage

    rocker [command] [app_name] [container_name]

*   `regen` 

    Regenerate the dockerfile

*   `rebuild`

    Regenerate the dockerfile

    Rebuild the image of container

*   `rerun`

    Rerun the container

*   `restart`

    Regenerate the dockerfile and rebuild the image of container.

    Rerun the container.

*   `destroy`

    Remove the container

*   `remove`

    Remove the container

    Clean the volume of container

*   `clean`

    Clean the volume of container

*   `setup`

    Setup the volume of container

# Extra Usage

*   `rocker run [app_name] [container_name] [method]`

    Run the instance [method] of Rockerfile

*   `rocker clean [app_name] [container_name] [filter]`

    Clean name matched directories in the volume of container

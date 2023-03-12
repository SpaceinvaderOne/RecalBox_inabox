# Base image
FROM ubuntu:latest

# Update package lists and install required packages
RUN apt-get update && \
    apt-get install -y avahi-daemon bash curl unzip qemu-utils sed libvirt-daemon gawk util-linux sshpass coreutils iputils-ping xz-utils uuid-runtime libvirt-clients && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory here
WORKDIR /app

# Copy the assets into the container
COPY letsgo.sh /app/
COPY recal.xml /app/
COPY recalbox-boot.conf /app/

# Set permissions
RUN chmod +x /app/letsgo.sh && \
    chmod 644 /app/recal.xml

# Expose the avahi-daemon port
EXPOSE 5353/udp

# Set entrypoint
ENTRYPOINT ["/app/letsgo.sh"]

# Keep the container running
CMD tail -f /dev/null


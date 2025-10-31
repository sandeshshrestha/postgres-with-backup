FROM postgres:18

# Install pgBackRest and required tools
RUN apt-get update && apt-get install -y \
    pgbackrest \
    cron \
    openssh-client \
    sshpass \
    && rm -rf /var/lib/apt/lists/*

# Create pgBackRest directories
RUN mkdir -p /var/lib/pgbackrest \
    && mkdir -p /var/log/pgbackrest \
    && mkdir -p /var/spool/pgbackrest \
    && mkdir -p /etc/pgbackrest \
    && mkdir -p /etc/pgbackrest/conf.d \
    && chown -R postgres:postgres /var/lib/pgbackrest \
    && chown -R postgres:postgres /var/log/pgbackrest \
    && chown -R postgres:postgres /var/spool/pgbackrest

# Create scripts directory
RUN mkdir -p /usr/local/bin/pgbackrest-scripts

# Copy pgBackRest configuration
COPY config/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

# Copy scripts
COPY scripts/pgbackrest-scripts/ /usr/local/bin/pgbackrest-scripts/
RUN chmod +x /usr/local/bin/pgbackrest-scripts/*.sh

# Copy entrypoint
COPY scripts/pgbackrest-scripts/entrypoint.sh /usr/local/bin/pgbackrest-entrypoint.sh
RUN chmod +x /usr/local/bin/pgbackrest-entrypoint.sh

# Set up cron log
RUN touch /var/log/pgbackrest-cron.log

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/pgbackrest-entrypoint.sh"]
CMD ["postgres"]

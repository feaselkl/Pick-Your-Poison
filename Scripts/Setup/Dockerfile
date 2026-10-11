# A SQL Server 2025 image with the "Pick Your Poison" demo databases baked in.
#
# The edition is a build argument, so the same Dockerfile produces all three
# images. docker-compose.yml sets it per service.
#
#   docker build --build-arg SQL_PID=StandardDeveloper -t pyp-standard .
#
# The seed script is edition-aware: Express skips CDC and TDE, which it cannot do.

FROM mcr.microsoft.com/mssql/server:2025-latest

# Named SQL_PID rather than MSSQL_PID: declaring an ARG and an ENV with the same
# name is a self-referencing collision in Docker and resolves unpredictably.
ARG SQL_PID=EnterpriseDeveloper

ENV ACCEPT_EULA=Y
ENV MSSQL_SA_PASSWORD=SqlServerDemo2025!
ENV MSSQL_PID=${SQL_PID}

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends mssql-tools18 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY seed-demo-database.sql /tmp/seed.sql

# /var/opt/mssql/backup is the shared volume mount point used by
# "03 - The Downgrade Reality Check.sql" to move a backup between instances.
RUN mkdir -p /var/opt/mssql/backup \
 && chown -R mssql:mssql /var/opt/mssql \
 && chown mssql:mssql /tmp/seed.sql

USER mssql

# Start the engine, seed it, wait for TDE to finish encrypting, then stop
# cleanly so the data files are consistent inside the image.
#
# Each image also gets a real server name (SQL2025-STD / -ENT / -EXP). Without
# that, every instance reports @@SERVERNAME as "buildkitsandbox" -- baked in at
# build time -- which makes the estate audit demo look broken.
#
# Launch through launch_sqlservr.sh, NOT sqlservr directly. The entrypoint
# translates the friendly edition names into the values the engine actually
# accepts (EnterpriseDeveloper -> Developer, StandardDeveloper ->
# DeveloperStandard) and runs the startup permissions check. Calling sqlservr
# directly fails with "The provided PID [EnterpriseDeveloper] is invalid."
RUN set -e; \
    SQLCMD="/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $MSSQL_SA_PASSWORD -C"; \
    echo "Edition: $MSSQL_PID"; \
    (/opt/mssql/bin/launch_sqlservr.sh /opt/mssql/bin/sqlservr > /tmp/sqlservr.log 2>&1 &) ; \
    echo "Waiting for SQL Server to accept connections..."; \
    for i in $(seq 1 120); do \
        $SQLCMD -l 2 -Q "SELECT 1" >/dev/null 2>&1 && { echo "  up after ${i}s"; break; }; \
        sleep 1; \
    done; \
    $SQLCMD -Q "SELECT 1" >/dev/null 2>&1 || { echo "FAILED: SQL Server never came up. Engine log:"; tail -40 /tmp/sqlservr.log; exit 1; }; \
    echo "Running seed..."; \
    $SQLCMD -i /tmp/seed.sql; \
    echo "Waiting for TDE encryption scan to complete (if enabled)..."; \
    for i in $(seq 1 90); do \
        state=$($SQLCMD -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL((SELECT MAX(encryption_state) FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('Contoso')), 3)" 2>/dev/null | head -1 | tr -d '[:space:]'); \
        [ "$state" = "3" ] && break; \
        sleep 2; \
    done; \
    echo "Verifying the seed actually landed..."; \
    rows=$($SQLCMD -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM Contoso.dbo.SalesFact" 2>/dev/null | head -1 | tr -d '[:space:]'); \
    case "$rows" in \
        ''|*[!0-9]*) echo "FAILED: could not read Contoso.dbo.SalesFact"; exit 1 ;; \
    esac; \
    [ "$rows" -ge 1000 ] || { echo "FAILED: SalesFact has only $rows rows"; exit 1; }; \
    echo "Seed verified: $rows rows in Contoso.dbo.SalesFact"; \
    case "$MSSQL_PID" in \
        StandardDeveloper)   SRV=SQL2025-STD ;; \
        EnterpriseDeveloper) SRV=SQL2025-ENT ;; \
        Express)             SRV=SQL2025-EXP ;; \
        *)                   SRV=SQL2025 ;; \
    esac; \
    echo "Setting server name to $SRV..."; \
    $SQLCMD -Q "EXEC sp_dropserver @@SERVERNAME; EXEC sp_addserver '$SRV', 'local';" >/dev/null 2>&1 || true; \
    $SQLCMD -Q "CHECKPOINT" >/dev/null 2>&1 || true; \
    pkill sqlservr; \
    sleep 10; \
    rm -f /tmp/seed.sql /tmp/sqlservr.log

EXPOSE 1433

CMD ["/opt/mssql/bin/sqlservr"]

#!/bin/bash
## vdt-entrypoint.sh
#
#  Custom entrypoint for the Oracle GoldenGate Veridata container.
#
#  First-run flow  (volume is empty / no PROPS file):
#    1. Run the Oracle installer as a background process
#    2. Poll until PROPS file appears (installer completed MySQL setup)
#    3. Kill the installer, fall through to the restart path
#
#  Restart flow  (PROPS file already exists):
#    4. Start MySQL (dual-mode ping: with or without root password)
#    5. If root has no password, set it to 'root' (happens after fresh install)
#    6. If Veridata schema is missing, create it from the bundled SQL scripts
#    7. Start the Veridata JVM and keep the container alive
#
#  Key fix vs original: installer was exec'd (replaced the shell), so the
#  restart path was unreachable when the installer failed mid-way.
#  Now the installer runs as a subprocess; the restart path always runs.

set -e

echo ">>> vdt-entrypoint.sh starting..."

# ── 1. Patch heap sizes ────────────────────────────────────────────────────
echo ">>> Patching heap sizes..."
sed -i "s/printf '%s\\\\n' 'MIN_HEAP_SIZE=8g'/printf '%s\\\\n' 'MIN_HEAP_SIZE=1g'/" \
  /usr/local/bin/generate_vdtca_rsp.sh 2>/dev/null || true
sed -i "s/printf '%s\\\\n' 'MAX_HEAP_SIZE=28g'/printf '%s\\\\n' 'MAX_HEAP_SIZE=4g'/" \
  /usr/local/bin/generate_vdtca_rsp.sh 2>/dev/null || true
echo ">>> Heap sizes patched (1g/4g)"

# ── 2. Fix libncurses symlinks ─────────────────────────────────────────────
# /usr/lib64 is root-owned; /tmp can be full on the Docker overlay layer.
# Use /u01/vdt/.lib (inside the named volume — always writable, always has space).
LIB_SHIM=/u01/vdt/.lib
mkdir -p "$LIB_SHIM" || true
ln -sf /usr/lib64/libncurses.so.6 "$LIB_SHIM/libncurses.so.5" 2>/dev/null || true
ln -sf /usr/lib64/libtinfo.so.6   "$LIB_SHIM/libtinfo.so.5"   2>/dev/null || true
export LD_LIBRARY_PATH="${LIB_SHIM}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo ">>> libncurses shims: $LIB_SHIM"

# ── 3. Set JAVA_HOME ──────────────────────────────────────────────────────
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
export JRE_HOME=$JAVA_HOME
echo ">>> JAVA_HOME: $JAVA_HOME"

# ── 4. First run: run installer as a subprocess, then fall through ─────────
PROPS="/u01/vdt/config/oggvdt_cainput.properties"

if [ ! -f "$PROPS" ]; then
    echo ">>> First run — starting installer in background..."

    /usr/local/bin/deployment-main.sh &
    INSTALLER_PID=$!
    echo ">>> Installer PID: $INSTALLER_PID"

    echo ">>> Waiting for installer to create properties file..."
    for i in $(seq 1 120); do           # up to 10 minutes
        if [ -f "$PROPS" ]; then
            echo ">>> Properties file found after ${i}x5s"
            break
        fi
        if ! kill -0 "$INSTALLER_PID" 2>/dev/null; then
            echo ">>> Installer process exited (PID $INSTALLER_PID)"
            [ -f "$PROPS" ] && break
            echo ">>> ERROR: installer exited without creating $PROPS" >&2
            exit 1
        fi
        if [ "$i" -eq 120 ]; then
            echo ">>> ERROR: installer timeout (10 min) — $PROPS not created" >&2
            kill "$INSTALLER_PID" 2>/dev/null || true
            exit 1
        fi
        echo ">>> Installer running... ($i/120)"
        sleep 5
    done

    # Give MySQL a moment to fully stabilise before we continue
    echo ">>> Installer phase complete — stopping installer process..."
    kill "$INSTALLER_PID" 2>/dev/null || true
    wait  "$INSTALLER_PID" 2>/dev/null || true
    sleep 3
fi

# ── 5. Restart path ───────────────────────────────────────────────────────
echo ">>> Properties found — continuing startup..."

sed -i 's/jvm.memory.xms=8g/jvm.memory.xms=1g/' "$PROPS" 2>/dev/null || true
sed -i 's/jvm.memory.xmx=28g/jvm.memory.xmx=4g/' "$PROPS" 2>/dev/null || true
echo ">>> Heap: $(grep 'jvm.memory' "$PROPS" | tr '\n' ' ')"

# ── 5a. Locate MySQL ──────────────────────────────────────────────────────
MYSQL_DIR=$(ls -d /u01/vdt/mysql-commercial-*/ 2>/dev/null | head -1)
if [ -z "$MYSQL_DIR" ]; then
    echo ">>> ERROR: MySQL directory not found under /u01/vdt/mysql-commercial-*/" >&2
    exit 1
fi
SOCKET="${MYSQL_DIR}data/mysql.sock"
ADMIN="${MYSQL_DIR}bin/mysqladmin"
MYSQL_CLI="${MYSQL_DIR}bin/mysql"
PID_FILE="${MYSQL_DIR}data/mysqld.pid"

echo ">>> MySQL dir : $MYSQL_DIR"

# ── 5b. Clean up stale pid / socket ──────────────────────────────────────
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
        echo ">>> Stale MySQL pid file (PID $OLD_PID not running) — cleaning up..."
        rm -f "$PID_FILE" "$SOCKET" "${SOCKET}.lock" 2>/dev/null || true
    fi
fi

# ── 5c. MySQL helpers ─────────────────────────────────────────────────────
#   mysql_ping    : server-alive check (try -proot, then no password)
#   run_sql_root  : execute SQL from stdin as root, same dual-mode auth
#
#   mysqladmin ping can succeed before full auth negotiation completes on a
#   fresh --initialize-insecure start, so the old conditional "if root has no
#   password" check is unreliable.  run_sql_root always tries both states.
mysql_ping() {
    "$ADMIN" -uroot -proot --socket="$SOCKET" ping --silent 2>/dev/null || \
    "$ADMIN" -uroot         --socket="$SOCKET" ping --silent 2>/dev/null
}

run_sql_root() {
    # run_sql_root [mysql_extra_args...]
    # Reads SQL from stdin; tries root password 'root' first, then no password.
    # Extra args (e.g. -D VDT23C_VERIDATA) are forwarded to both mysql calls.
    local _sql
    _sql=$(cat)
    echo "$_sql" | "$MYSQL_CLI" -uroot -proot --socket="$SOCKET" "$@" 2>/dev/null || \
    echo "$_sql" | "$MYSQL_CLI" -uroot         --socket="$SOCKET" "$@" 2>/dev/null
}

# ── 5d. Start MySQL if not running ───────────────────────────────────────
if mysql_ping; then
    echo ">>> MySQL already running"
else
    echo ">>> Starting MySQL..."
    nohup "${MYSQL_DIR}bin/mysqld_safe" \
        --user=ogg \
        --datadir="${MYSQL_DIR}data" \
        --socket="$SOCKET" \
        --pid-file="$PID_FILE" \
        --log-error="${MYSQL_DIR}mysqld.log" \
        --innodb-buffer-pool-size=256M \
        >/dev/null 2>&1 &

    echo ">>> Waiting for MySQL to start..."
    for i in $(seq 1 60); do
        if mysql_ping; then
            echo ">>> MySQL ready after ${i}x5s"
            break
        fi
        [ "$i" -eq 60 ] && echo ">>> ERROR: MySQL startup timeout" >&2 && exit 1
        echo ">>> Waiting... ($i/60)"
        sleep 5
    done
fi

# ── 5e. Ensure root has password 'root' ──────────────────────────────────
#   Unconditionally (re-)set root password via run_sql_root, which tries
#   no-password then -proot.  On fresh install (no password) the first try
#   succeeds; on restart (already 'root') the second try is a no-op.
echo ">>> Ensuring root password is 'root'..."
run_sql_root <<'SQLEOF' || true
ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';
FLUSH PRIVILEGES;
SQLEOF
echo ">>> Root password ensured"

# ── 5f. Ensure Veridata schema (VDT23C_VERIDATA) exists ──────────────────
#   The installer creates the database and runs the V*.sql migration scripts.
#   Since we kill the installer early, we do it ourselves:
#     1. CREATE DATABASE IF NOT EXISTS (idempotent)
#     2. Run each V*.sql inside that database (scripts contain only DDL/DML,
#        no CREATE DATABASE / USE statements of their own).
SCHEMA_EXISTS=$(echo "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
    WHERE SCHEMA_NAME='VDT23C_VERIDATA';" | run_sql_root \
    | grep -w "VDT23C_VERIDATA" || echo "")

if [ -z "$SCHEMA_EXISTS" ]; then
    echo ">>> Veridata schema not found — creating database and running migration scripts..."
    # Step 1: create the database
    echo "CREATE DATABASE IF NOT EXISTS VDT23C_VERIDATA CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        | run_sql_root || true
    # Step 2: run versioned SQL scripts inside the database
    SQL_DIR="/u01/vdt/config/repo_schema_sql/mysql"
    for f in $(ls "${SQL_DIR}"/V*.sql 2>/dev/null | sort); do
        echo "  Applying: $(basename "$f")"
        run_sql_root -D VDT23C_VERIDATA < "$f" || true
    done
    echo ">>> Veridata schema created"
else
    echo ">>> Veridata schema already exists"
fi

# ── 5g. Create MySQL veridata user + complete quartz.properties ──────────
#   The installer reads repo credentials from oggvdt_cainput.properties and
#   (a) creates the MySQL 'veridata' user, and
#   (b) writes URL/user/password into quartz.properties.
#   Since we kill the installer early, we do both steps here.

CONFIG_DIR=/u01/vdt/config   # also used in 5j; defined early so 5g can use it

REPO_USER=$(grep '^repository.user='     "$PROPS" 2>/dev/null | head -1 \
            | cut -d= -f2 | tr -d '\r\n\\')
REPO_PASS=$(grep '^repository.password=' "$PROPS" 2>/dev/null | head -1 \
            | cut -d= -f2 | tr -d '\r\n\\')
REPO_URL=$(grep  '^repository.url='      "$PROPS" 2>/dev/null | head -1 \
            | sed 's/^repository\.url=//' | sed 's/\\:/:/g; s/\\=/=/g' | tr -d '\r\n')

REPO_USER="${REPO_USER:-veridata}"
REPO_PASS="${REPO_PASS:-veridata}"
REPO_URL="${REPO_URL:-jdbc:mysql://localhost:3306/VDT23C_VERIDATA?allowPublicKeyRetrieval=true&autoReconnect=true}"

echo ">>> Creating MySQL user '${REPO_USER}' with grants on VDT23C_VERIDATA..."
run_sql_root <<SQLEOF || true
CREATE USER IF NOT EXISTS '${REPO_USER}'@'localhost' IDENTIFIED BY '${REPO_PASS}';
ALTER  USER              '${REPO_USER}'@'localhost' IDENTIFIED BY '${REPO_PASS}';
GRANT ALL PRIVILEGES ON VDT23C_VERIDATA.* TO '${REPO_USER}'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
echo ">>> MySQL user '${REPO_USER}' configured"

echo ">>> Completing quartz.properties datasource config..."
sed -i '/^org\.quartz\.dataSource\.myDS\.\(URL\|user\|password\)=/d' \
    "$CONFIG_DIR/quartz.properties" 2>/dev/null || true
printf '\norg.quartz.dataSource.myDS.URL=%s\norg.quartz.dataSource.myDS.user=%s\norg.quartz.dataSource.myDS.password=%s\n' \
    "$REPO_URL" "$REPO_USER" "$REPO_PASS" >> "$CONFIG_DIR/quartz.properties"
echo ">>> quartz.properties datasource configured"

# ── 5g2. Insert Veridata admin user into MySQL schema ─────────────────────
#   The installer adds the 'veridata' admin user to the USERS table during
#   its setup phase.  Since we kill the installer early, that step never
#   runs.  UserServiceImpl.addUsers() calls getAllUsers() from MySQL to
#   populate Helidon's user store.  With an empty USERS table every Basic-
#   auth login returns 401 — there is literally no user to authenticate.
#
#   Fix: INSERT the admin user (idempotent via INSERT IGNORE).
#   Password is handled separately by config-assist → UserWallet.
VDT_ADMIN_USER_NAME="${VDT_ADMINISTRATOR_USER:-veridata}"
echo ">>> Ensuring Veridata admin user '${VDT_ADMIN_USER_NAME}' exists in MySQL schema..."
run_sql_root -D VDT23C_VERIDATA <<SQLEOF || true
-- Insert admin user with id=0 (idempotent)
INSERT IGNORE INTO USERS (id, name, created_at, modified_at)
VALUES (0, '${VDT_ADMIN_USER_NAME}', NOW(), NOW());

-- Assign admin user to Administrators group (id=0)
INSERT IGNORE INTO USERS_USERGROUPS (users_id, USERGROUPS_ID)
SELECT 0, 0
FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM USERS_USERGROUPS
    WHERE users_id = 0 AND USERGROUPS_ID = 0
);
SQLEOF
echo ">>> Admin user DB record ensured"

# ── 5h. Keystore ─────────────────────────────────────────────────────────
KEYSTORE="/u01/vdt/config/vdtWebKeystore.p12"
if [ ! -f "$KEYSTORE" ]; then
    echo ">>> Generating keystore..."
    bash /u01/vdt/script/vdtca/generate_self_signed_cert.sh \
        "$KEYSTORE" veridata oggvdt 2>&1 || true
    cp /u01/vdt/script/vdtca/vdtWebKeystore.p12 "$KEYSTORE" 2>/dev/null || true
fi

# ── 5i. Start Veridata agent ──────────────────────────────────────────────
if [ -n "${VDT_AGENT_JDBC_DATABASE_URL:-}" ]; then
    echo ">>> Starting Veridata agent..."
    /usr/local/bin/configure_deploy_agent.sh || true
fi

# ── 5j. Start Veridata JVM ────────────────────────────────────────────────
echo ">>> Starting Veridata JVM..."
LOGS_DIR=/u01/vdt/veridata/logs
mkdir -p "$LOGS_DIR"

sed -i 's/^\(.*\.formatter=\).*/\1com.oracle.goldengate.veridata.logging.ThreadLogFormatter/' \
    "$CONFIG_DIR/logging.properties" 2>/dev/null || true

# Substitute ${logs.dir} placeholder — the installer normally does this but
# we start the JVM before the installer fully completes.
sed -i "s|\${logs.dir}|${LOGS_DIR}|g" \
    "$CONFIG_DIR/logging.properties" 2>/dev/null || true
echo ">>> Logging dir: ${LOGS_DIR}"

cp "$CONFIG_DIR/jps-config-template.xml" "$CONFIG_DIR/jps-config-jse.xml" 2>/dev/null || true
# Set credential store location to CONFIG_DIR (where cwallet.sso lives).
# run.sh resolves CREDENTIAL_LOCATION env-var (default "."); we pin it to an
# absolute path so the wallet is found regardless of working directory.
sed -i.bak \
    -E "s|<serviceInstance name=\"credstore\" provider=\"credstoressp\" location=\"[^\"]*\">|<serviceInstance name=\"credstore\" provider=\"credstoressp\" location=\"${CONFIG_DIR}\">|g" \
    "$CONFIG_DIR/jps-config-jse.xml" 2>/dev/null || true

cd /u01/vdt/bin
export APP_HOME=/u01/vdt

# ── Restore credentials before config-assist ─────────────────────────────
#   config-assist reads veridata.admin.password (and repository.password)
#   from oggvdt_cainput.properties, writes them into the JPS wallet
#   (cwallet.sso), and then STRIPS those keys from the file as a security
#   measure.  On restart the file has no password so config-assist does
#   nothing → wallet stays empty → 401 on every login.
#
#   Fix: re-inject both passwords before every config-assist run.
#   VDT_ADMINISTRATOR_PASSWORD is always available from the container env.
echo ">>> Restoring credentials to properties for config-assist..."
_CA_ADMIN_USER="${VDT_ADMINISTRATOR_USER:-veridata}"
_CA_ADMIN_PASS="${VDT_ADMINISTRATOR_PASSWORD:?ERROR: VDT_ADMINISTRATOR_PASSWORD not set in container environment.}"
_CA_REPO_PASS="${REPO_PASS:-veridata}"
# NOTE: Do NOT escape '#' as '\#' here.  In Java .properties files '#' only
# starts a comment at the very beginning of a line; inside a value it is
# literal.  Helidon Config (which loads this file) does NOT unescape '\#',
# so writing 'Welcome\#\#123' would be compared literally as such and fail.
# Write the raw value — both Java Properties and Helidon Config treat it as
# 'Welcome##123'.  The installer's '\#' escaping is only needed by its own
# custom reader; for our entrypoint the unescaped form is correct.

# Remove any leftover or previously-written lines, then append fresh values
sed -i \
    '/^veridata\.admin\.password=/d
     /^veridata\.admin\.username=/d
     /^repository\.password=/d' \
    "$CONFIG_DIR/oggvdt_cainput.properties" 2>/dev/null || true
{
    printf 'veridata.admin.username=%s\n' "$_CA_ADMIN_USER"
    printf 'veridata.admin.password=%s\n' "$_CA_ADMIN_PASS"
    printf 'repository.password=%s\n'     "$_CA_REPO_PASS"
} >> "$CONFIG_DIR/oggvdt_cainput.properties"
echo ">>> Credentials restored (admin=${_CA_ADMIN_USER}, repo=${REPO_USER:-veridata})"

# ── Config-assist phase (mirrors run.sh) ──────────────────────────────────
#   run.sh always runs services.jar with -Dis_config_assist=true first.
#   This reads credentials from oggvdt_cainput.properties and writes them
#   into the JPS wallet (cwallet.sso) — including the SSL keystore path.
#   Without this the server logs: "veridata does not have password store in
#   the wallet" and getKeyStorePath() returns null (SSL disabled, port 8831
#   unreachable).
echo ">>> Running config-assist to populate JPS credential wallet..."
java \
    -Dis_config_assist=true \
    -DAPP_HOME=/u01/vdt \
    -Djava.security.egd=file:/dev/urandom \
    -Dapp_yaml_path=$CONFIG_DIR/application.yaml \
    -Dapp_prop_path=$CONFIG_DIR/oggvdt_cainput.properties \
    -Doracle.veridata.domain.home=$CONFIG_DIR \
    -Doracle.security.jps.config=$CONFIG_DIR/jps-config-jse.xml \
    -Dquartz_prop_path=$CONFIG_DIR/quartz.properties \
    -Djava.util.logging.config.file=$CONFIG_DIR/logging.properties \
    -Dlogs.dir=$LOGS_DIR \
    -jar /u01/vdt/services.jar 2>&1 || true
echo ">>> Config-assist complete"
# Show wallet size so we can confirm it was written
echo ">>> Wallet size: $(stat -c%s "$CONFIG_DIR/cwallet.sso" 2>/dev/null || echo 'unknown') bytes"

java -Xms1g -Xmx4g \
    -DAPP_HOME=/u01/vdt \
    -Doracle.jipher.fips=true \
    -Djava.security.egd=file:/dev/urandom \
    -Dhelidon.config.polling.enabled=false \
    -Djdk.tls.client.protocols=TLSv1.2 \
    -Djdk.tls.disabledAlgorithms="SSLv3,TLSv1,TLSv1.1,MD5,SHA1" \
    -Dapp_yaml_path=$CONFIG_DIR/application.yaml \
    -Dapp_prop_path=$CONFIG_DIR/oggvdt_cainput.properties \
    -Doracle.veridata.domain.home=/u01/vdt \
    -Doracle.security.jps.config=$CONFIG_DIR/jps-config-jse.xml \
    -Dquartz_prop_path=$CONFIG_DIR/quartz.properties \
    -Djava.util.logging.config.file=$CONFIG_DIR/logging.properties \
    -Djava.locale.providers=COMPAT,CLDR,SPI \
    -Xlog:gc*:file=$LOGS_DIR/veridata-gc-xlog.log:time,uptime:filecount=1,filesize=5M \
    -XX:+UseG1GC -XX:ParallelGCThreads=2 -XX:ConcGCThreads=2 \
    -XX:+UseStringDeduplication \
    -Dlogs.dir=$LOGS_DIR \
    -jar /u01/vdt/services.jar &

RUN_PID=$!
echo ">>> Veridata JVM started as PID $RUN_PID"

trap "echo '>>> Shutting down...'; kill -15 $RUN_PID 2>/dev/null" SIGTERM SIGINT

wait $RUN_PID
echo ">>> Veridata JVM exited, container shutting down."

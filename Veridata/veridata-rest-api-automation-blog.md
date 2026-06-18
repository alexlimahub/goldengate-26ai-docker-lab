# Automating Oracle GoldenGate Veridata 26 with the REST API

**Author:** Alex Lima, GoldenGate Product Manager
**Date:** March 17, 2026
**Tags:** `Oracle GoldenGate` `Veridata` `REST API` `Automation` `Data Validation` `Shell Scripting`

---

## Introduction

In modern enterprise environments, data validation is not a one-time event — it is a continuous, automated process. Whether you are executing a large-scale database migration, running a live replication environment with Oracle GoldenGate, or maintaining a disaster recovery setup, you need confidence that your source and target databases are in sync at all times.

Oracle GoldenGate Veridata is purpose-built for exactly this. It compares source and target databases row-by-row, identifies discrepancies, and optionally repairs them — all without impacting the production workload. But for enterprise teams managing dozens or hundreds of comparison workflows, manually clicking through a web interface is not scalable.

This is where the **Veridata 26 REST API** becomes a game changer. Every step of the Veridata lifecycle — from deploying agents to scheduling nightly comparison jobs — can be fully automated through a clean, documented REST interface. In this post, I will walk through a complete end-to-end automation workflow built entirely with shell scripts and `curl`, explaining not just *what* each step does, but *why* it is necessary and what it means for your deployment.

---

## What We'll Build

By the end of this walkthrough, you will have a fully scripted, repeatable pipeline that:

1. Deploys and starts a second Veridata agent
2. Verifies both agents are up and running
3. Creates a performance-tuned comparison profile
4. Creates source and target connections
5. Creates a compare group with all HR schema tables
6. Runs the comparison job and polls for results
7. Schedules the job to run automatically every night at midnight

All scripts are **idempotent** — safe to re-run at any time without causing duplicates or errors.

---

## Architecture Overview

Before diving into the scripts, it helps to understand how Veridata works architecturally.

```
┌─────────────────────────────────────────────────────┐
│                  oggvdt Container                    │
│                                                     │
│   Agent 1 (port 6826)    Agent 2 (port 6827)        │
│   → DB: 172.52.0.103     → DB: 172.52.0.104         │
│     (WEST connection)      (EAST connection)        │
│                                                     │
│              Veridata Server (port 8831)            │
└─────────────────────────────────────────────────────┘
          ↑
   REST API calls from Mac (curl)
```

The Veridata architecture has three tiers:

- **Veridata Server** — the orchestration engine. It receives jobs, coordinates comparisons, stores results, and exposes the REST API. It does not talk directly to the databases.
- **Veridata Agents** — lightweight Java processes deployed next to each database. They execute the actual SQL queries, fetch rows, hash and compress the data, and stream it back to the server for comparison. Each agent is dedicated to one database connection.
- **Databases** — the Oracle (or other) databases being compared. The agents connect to them using JDBC.

In this lab setup, both databases live in the same Docker container (`oggvdt`), so we need **two separate agent deployments** on different ports — one for each database. This is an important concept: **one agent = one database endpoint**, regardless of physical location.

---

## Step 1 — Deploy a Second Veridata Agent

### Why is this needed?

The first agent deployment (`/u01/vdt_agent_deployment`, port 6826) was created during the initial Veridata installation and is already pointing to the source database at `172.52.0.103`. To compare the source against a second database at `172.52.0.104`, we need a second, independent agent deployment. Each agent maintains its own connection pool, port binding, JDBC configuration, and log files — they must be completely isolated from each other.

Without this second agent, Veridata has no way to reach the target database. The comparison would fail at the connection level before a single row is read.

### What the script does

```bash
./create_veridata_agent2.sh
```

The script performs a clean deployment cycle:

**Cleanup (idempotency):**
- Uses `ss -tlnp` to check if any process is already bound to port `6827`
- If found, kills it with `kill -9` and waits 3 seconds for the OS to release the port
- Removes the old deployment directory `/u01/vdt_agent_deployment_2` if it exists
- This ensures every run starts from a clean, known state

**Deployment:**
- Runs `agent_config.sh /u01/vdt_agent_deployment_2` — Oracle's official tool that creates the full deployment structure (config directories, startup scripts, log directories)
- Copies `agent.properties` from the first deployment as a base template

**Configuration via `sed`:**
- `server.port=6827` — binds this agent to a different port so it coexists with Agent 1
- `database.url=jdbc:oracle:thin:@172.52.0.104:1521/freepdb1` — points to the target database
- `server.driversLocation=/u01/vdt/agent/drivers` — shared driver location
- `server.jdbcDriver=ojdbc11-23.9.0.25.07.jar` — specifies the exact Oracle JDBC driver JAR

**Startup:**
- Starts the agent with `nohup ... &` so it persists after the shell session ends
- Redirects output to `agent.log` for later troubleshooting

> **Key engineering lesson:** The cleanup step uses separate `docker exec` calls rather than running `pkill` inside the main bash session. This is critical — if `pkill` ran inside the same `bash -c "..."` process, it would match its own process (since the script text contains the search pattern) and kill itself before completing. Separating the kill step into an independent `docker exec` invocation eliminates this self-termination race condition.

> **Another pitfall:** `lsof` is the standard Unix tool for finding processes by port, but it is frequently absent in Oracle Linux containers. `ss` (socket statistics) is part of the `iproute2` package which is always present — use it instead.

---

## Step 2 — Verify Both Agents Are Running

### Why is this needed?

Agent startup is asynchronous — the `nohup` command returns immediately while the Java process initializes in the background. The JVM takes several seconds to load, bind to the port, and establish the database connection pool. If you immediately proceed to configure connections in the Veridata Server without first confirming the agents are up, the connection tests will fail and you'll have to debug why.

More importantly, agents can fail silently. If the JDBC driver is missing, the port is already in use, or there's a database connectivity issue, the agent process dies after launch — and you won't know unless you check. This verification step surfaces those failures early.

### What the script does

```bash
./check_veridata_agents.sh
```

For each agent (ports 6826 and 6827), the script:
- Runs `ss -tlnp` inside the container to find the PID bound to the port
- Reports `UP` with the PID if the port is listening, `DOWN` if not
- Tails the last 5 lines of `agent.log` regardless — so you can see startup messages or errors

```
--- 'Agent 1 - vdt_agent_deployment' ---
  Status : UP
  PID    : 1234
  Port   : 6826

--- 'Agent 2 - vdt_agent_deployment_2' ---
  Status : UP
  PID    : 2366
  Port   : 6827
  Last log lines:
    Veridata Agent running on oggvdt port 6827
```

---

## Step 3 — Create a Performance-Tuned Profile

### Why is this needed?

A Veridata **profile** is a named collection of runtime parameters that governs *how* a comparison executes — not *what* it compares. Think of it as the execution plan configuration for the comparison engine. Without a custom profile, Veridata uses the `$default` profile, which is conservative and designed to work safely on any hardware. For production workloads, the defaults are often far too cautious.

The two most impactful parameters are:

1. **`ProfileGeneralMaxParallelCompares`** (default: 4) — controls how many table comparisons run simultaneously. On a modern server with 16 or 32 CPU cores, running only 4 parallel comparisons leaves most of the hardware idle. Increasing this directly multiplies throughput.

2. **`COOSBatchSize`** (default: 1,000) — controls how many out-of-sync rows are processed per batch in the Confirm Out-of-Sync (COOS) phase. For tables with thousands of OOS rows, a batch size of 1,000 means thousands of round-trips to the database. Increasing to 10,000 or 50,000 dramatically reduces that overhead.

Profiles also control the COOS phase behavior, sorting strategy, Oracle optimizer hints, repair settings, and reporting intervals. Creating the right profile for your workload is the single fastest way to improve Veridata performance.

### What the script does

```bash
./create_veridata_profile.sh --scenario medium --profile HR_PROFILE
```

The script supports two categories of scenarios:

**Size-based scenarios** (recommended starting point for customers):

| Scenario | Best for | Key settings |
|---|---|---|
| `small` | < 100k rows | 2 threads, batch 1k |
| `medium` | 100k – 10M rows | 4 threads, batch 10k, 30s reporting |
| `large` | > 10M rows | 8 threads, batch 50k, Oracle `PARALLEL` hints |

**Advanced scenarios** for specific situations:

| Scenario | When to use |
|---|---|
| `high-oos` | Expecting >10k out-of-sync rows |
| `db-load` | Database is under heavy load — use server-side sorting |
| `baseline` | First-time scan, disable COOS for maximum speed |
| `repair` | Running automated data repairs after compare |
| `replication-lag` | Replication is behind — delay COOS to avoid false positives |

**Under the hood**, it performs two API calls:

1. `POST /veridata/v1/services/configuration/profiles` — creates the profile, cloning all settings from `$default` as the base
2. `PATCH /veridata/v1/services/configuration/profiles/{id}` — applies only the attributes that differ from the default

```json
{
  "attributesList": [
    {"name": "ProfileGeneralMaxParallelCompares", "default": false, "value": "4"},
    {"name": "COOSBatchSize",                     "default": false, "value": "10000"},
    {"name": "COOSConcurrent",                    "default": false, "value": "true"}
  ]
}
```

> **Why clone from `$default`?** Because the default profile contains dozens of pre-configured parameters. Cloning it ensures we inherit all the safe defaults and only override the ones we explicitly want to change. Creating a profile from scratch would require specifying every parameter, making the script brittle against future Veridata updates that add new profile attributes.

---

## Step 4 — Create Source and Target Connections

### Why is this needed?

Connections are the bridge between the Veridata Server and the Veridata Agents. They define:
- **Which agent host and port** the server should contact to initiate a comparison
- **Which database credentials** the agent should use to connect to the database
- **Which database type** (Oracle, PostgreSQL, SQL Server, etc.) so the agent uses the right JDBC driver behavior

A connection is not a live socket — it is a stored configuration that the server uses at job execution time. When a comparison job starts, the server opens a control channel to the agent on the specified host:port, passes the job parameters, and the agent then opens its own JDBC connection to the database using the stored credentials.

In our architecture:
- `WEST` = Agent 1 on port 6826, connects to the source database (`172.52.0.103`)
- `EAST` = Agent 2 on port 6827, connects to the target database (`172.52.0.104`)

### What the script does

```bash
./create_veridata_connections.sh
```

For each connection, it calls `POST /veridata/v1/services/configuration/connections`:

```json
{
  "name":     "WEST",
  "host":     "oggvdt",
  "port":     6826,
  "dbType":   "ORACLE",
  "ssl":      false,
  "username": "HR",
  "password": "Welcome##123"
}
```

Output:
```
--- Creating connection: WEST (agent port 6826) ---
  ✅ Created successfully (HTTP 201) — ID: 1001

--- Creating connection: EAST (agent port 6827) ---
  ✅ Created successfully (HTTP 201) — ID: 1002
```

> **Why use the container hostname `oggvdt` instead of `localhost`?** Because the Veridata Server itself runs inside the container and resolves `oggvdt` as the container's own hostname. Using `localhost` would work too in this case, but `oggvdt` is more explicit and works correctly in multi-container or multi-host deployments where the server and agents are on different machines.

---

## Step 5 — Create Compare Group and Pairs

### Why is this needed?

Veridata organizes comparisons into two levels:

- A **group** defines the comparison scope: which source connection maps to which target connection, and which profile governs the execution. Think of a group as a project — it owns a set of tables to compare and knows which agent pair to use.

- **Compare pairs** are the individual table mappings within a group. Each compare pair says: "compare table X on the source (via WEST) against table Y on the target (via EAST)." In most cases X and Y have the same name and schema, but Veridata supports cross-schema and cross-name comparisons for migration scenarios.

This two-level structure allows you to organize large comparison workloads logically — you might have one group for transactional tables, another for reference data tables, and another for audit tables, each with different profiles and schedules.

### What the script does

```bash
./create_veridata_group_and_pairs.sh
```

**Step 1 — Create the group** via `POST /veridata/v1/services/configuration/groups`:
```json
{
  "name":               "HR_COMPARE",
  "description":        "HR schema comparison: WEST vs EAST",
  "sourceConnectionId": 1001,
  "targetConnectionId": 1002
}
```

**Step 2 — Build the compare pairs payload** by querying all HR schema tables from the source database and constructing a single batch API call. This is important: instead of making 7 separate API calls (one per table), the script builds a single payload with all 7 pairs and submits them in one request to `POST /veridata/v1/services/configuration/groups/{id}/comparepairs`. This is significantly faster for large schemas with hundreds of tables.

```
--- Creating compare pairs in group ID: 1002 ---
  ✅ Compare pairs created (HTTP 201)
  Pairs created:
    • HR.EMPLOYEES    (WEST) ↔ HR.EMPLOYEES    (EAST)
    • HR.DEPARTMENTS  (WEST) ↔ HR.DEPARTMENTS  (EAST)
    • HR.JOBS         (WEST) ↔ HR.JOBS         (EAST)
    • HR.JOB_HISTORY  (WEST) ↔ HR.JOB_HISTORY  (EAST)
    • HR.LOCATIONS    (WEST) ↔ HR.LOCATIONS    (EAST)
    • HR.COUNTRIES    (WEST) ↔ HR.COUNTRIES    (EAST)
    • HR.REGIONS      (WEST) ↔ HR.REGIONS      (EAST)
```

> **Why batch the compare pairs?** For schemas with 50, 100, or 500 tables, making individual API calls per table would be slow and prone to rate-limiting or connection exhaustion. The batch approach is both faster and more reliable at scale.

---

## Step 6 — Run the Comparison and Poll for Results

### Why is this needed?

With agents running, connections defined, a profile configured, and compare pairs created — everything is in place. The comparison job is what triggers Veridata to actually start fetching and comparing data.

Veridata separates job *definition* from job *execution* deliberately. A stored job definition can be re-run multiple times (manually or on a schedule) without reconfiguring the groups or compare pairs. This separation is what makes the nightly scheduling in Step 7 possible.

The comparison itself runs in two phases:
1. **Initial Compare (InitComp)** — fetches all rows from both source and target simultaneously, hashes and sorts them, and identifies which rows exist only on one side or have different values.
2. **Confirm Out-of-Sync (COOS)** — re-fetches only the rows flagged as out-of-sync by InitComp and re-verifies them. This catches rows that were mid-replication during the first scan ("in-flight" rows) and avoids false positives. COOS runs concurrently with InitComp by default.

### What the script does

```bash
./run_veridata_comparison.sh
```

The script follows a four-step sequence:

1. **Look up the group ID dynamically** — queries `GET /services/configuration/groups` and filters by name. Group IDs can change between script runs (e.g., if the group was deleted and recreated), so hardcoding IDs would make the script fragile.

2. **Create the job** via `POST /services/configuration/jobs` — a job is a stored execution configuration that references one or more groups.

3. **Execute the job** via `POST /services/execution/jobs/{id}` — triggers the actual comparison. The response is a plain string like `1011/0/0` (not JSON), where the first number is the Run ID.

4. **Poll for completion** via `GET /services/monitoring/jobs` — queries job run statistics every 5 seconds until `status` reaches a terminal state (`OUTOFSYNC`, `INSYNC`, `ERROR`, or `ABORTED`).

```
--- Polling job status (Job: HR_COMPARE_JOB | Run ID: 1011) ---
  Status: OUTOFSYNC  |  Running: 0/7  |  In-Sync: 6  |  Out-of-Sync: 1  |  Errors: 0

==> Job completed
    Status      : OUTOFSYNC
    In-Sync     : 6 / 7
    Out-of-Sync : 1 / 7
    Errors      : 0
⚠️  Out-of-sync rows detected. Review in the Veridata UI: https://localhost:8831
```

> **Important API quirks discovered during this lab:**
> - The execute endpoint returns a **plain string** (`1011/0/0`), not JSON. Extract the run ID with `cut -d/ -f1`.
> - The monitoring endpoint does **not** support `?runId=` filtering. You must query all recent jobs and filter by `jobId` in the client.
> - The status field is named `status` (not `state`), and values are `OUTOFSYNC` and `INSYNC` — no underscores, unlike what the API documentation suggests.
> - In-sync count is `comparePairsWithNoOOS`, not `inSync`.

---

## Step 7 — Schedule the Job

### Why is this needed?

Running a comparison manually is useful during initial setup and debugging, but the real value of data validation comes from **continuous, automated monitoring**. In a live replication environment, data drift can occur at any time — a failed replication transaction, a schema change, a network hiccup, or a DBA operation on the target. You want to know about it as soon as possible, not the next time someone remembers to run a script.

Scheduling the comparison to run every night at midnight serves several purposes:
- **Proactive drift detection** — you wake up every morning with a validation report
- **Trend analysis** — comparing results over time reveals whether drift is increasing (replication issue) or stable (expected difference)
- **SLA compliance** — many migration and DR projects require proof of continuous data validation
- **Audit trail** — Veridata maintains a history of all run results, giving you a timestamped record of data integrity

### What the script does

```bash
./schedule_veridata_job.sh
```

Uses the dedicated scheduling endpoint with **6-field Quartz cron** format (Veridata uses the Quartz scheduler internally):

```json
{
  "type": "COMPARE",
  "scheduleDetails": [{
    "schedulePattern": "0 0 0 * * ?",
    "params": {
      "jobId":     1003,
      "isEnabled": true
    }
  }]
}
```

**Quartz cron format:** `seconds minutes hours day-of-month month day-of-week`

`0 0 0 * * ?` = at second 0, minute 0, hour 0 (midnight), every day of the month, every month, any day of the week.

Once scheduled, the job runs automatically without any manual intervention. You can update the schedule with `PATCH` or remove it entirely with `DELETE` on `/services/configuration/schedule/jobs/{id}`.

> **Why use Quartz and not standard Unix cron?** Veridata manages its own scheduler internally so that the schedule travels with the job configuration — it does not depend on an external cron daemon, a specific OS, or a particular machine. The Quartz scheduler also supports more complex patterns like "every 15 minutes on weekdays" or "first day of every month."

---

## The Complete Workflow

Here is the full repeatable pipeline — from a blank Veridata server to a running, scheduled nightly comparison:

```bash
./create_veridata_agent2.sh             # 1. Deploy & start Agent 2
./check_veridata_agents.sh              # 2. Verify both agents are UP
./create_veridata_profile.sh \
  --scenario medium \
  --profile HR_PROFILE                  # 3. Create performance profile
./create_veridata_connections.sh        # 4. Create WEST & EAST connections
./create_veridata_group_and_pairs.sh    # 5. Create group + 7 compare pairs
./run_veridata_comparison.sh            # 6. Run job + poll → show results
./schedule_veridata_job.sh              # 7. Schedule daily at midnight
```

---

## Performance Tuning Cheat Sheet

| Profile Attribute | Default | Small | Medium | Large |
|---|---|---|---|---|
| `ProfileGeneralMaxParallelCompares` | 4 | 2 | 4 | 8 |
| `COOSBatchSize` | 1,000 | 1,000 | 10,000 | 50,000 |
| `COOSConcurrent` | true | true | true | true |
| `InitCompRptRptIntervalSecs` | 0 | 0 | 30 | 60 |
| Oracle `PARALLEL` hints | none | none | none | `PARALLEL(t,4)` |

> For tables with **>10,000 out-of-sync rows**, also set `coos.batch.fetch=true` in `agent.properties` to switch COOS from single-row to batch-fetch mode. This can reduce COOS phase time by 80% or more on large OOS datasets.

---

## Key Takeaways

1. **Every Veridata operation is scriptable** — the REST API covers the full lifecycle from agent setup to job scheduling. There is no step in the UI that cannot be automated.

2. **Profiles are your performance lever** — the default profile is conservative by design. Matching the profile scenario to your table size is the single fastest way to improve throughput. For large tables, the difference between default and optimized settings can be 5-10x.

3. **Understand the two-phase comparison** — InitComp and COOS serve different purposes. Disabling COOS (`baseline` scenario) speeds up the first scan but does not catch in-flight rows. For live replication environments, always run COOS.

4. **Idempotent scripts are essential** — every script in this workflow checks for existing resources and reuses or recreates them gracefully. This means you can re-run the entire pipeline after a container restart without manual cleanup.

5. **Container automation has real quirks** — `pkill` self-match, `lsof` availability, `ss` vs `netstat`, and process-vs-port timing are all real-world pitfalls. The solutions are not obvious until you hit them.

6. **The REST API has undocumented behaviors** — the plain-string execute response, the lack of `runId` filtering in monitoring, and the field naming inconsistencies (`status` vs `state`, `OUTOFSYNC` vs `OUT_OF_SYNC`) are gaps that only surface during actual automation. Document them when you find them.

---

## Resources

- [Oracle GoldenGate Veridata 26 REST API Reference](https://docs.oracle.com/en/database/goldengate/veridata/26/ggvra/)
- [Oracle GoldenGate Veridata 26 Documentation](https://docs.oracle.com/en/database/goldengate/veridata/26/)
- [Profile Parameters Reference](https://docs.oracle.com/en/middleware/goldengate/veridata/12.2.1.4/gvdad/profile-parameters.html)
- [Sizing Oracle GoldenGate Veridata](https://blogs.oracle.com/dataintegration/post/how-to-size-oracle-goldengate-veridata)
- [Veridata 23c Basic Performance Tuning](https://blogs.oracle.com/dataintegration/post/oracle-goldengate-veridata-23c-basic-performance-tuning)

---

*All scripts referenced in this post are available in the lab repository.*
*© 2026 Alex Lima, Oracle GoldenGate Product Management*

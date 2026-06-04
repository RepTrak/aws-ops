# AWS Ops Navigator

An infinite-canvas architecture explorer for AWS infrastructure snapshots, built with React 18 and React Flow.

---

## Quick start

```bash
cd navigator
npm install
npm run dev          # opens http://localhost:5173
```

The dev server serves the parent `snapshots/` directory automatically via a Vite middleware. Two demo snapshots are included in the repo — no export step needed to get started.

---

## Production build

```bash
npm run build        # outputs to navigator/dist/
```

Serve from the repo root:

```bash
cd ..
python3 -m http.server 8000
# open http://localhost:8000/navigator/dist/
```

---

## Core concepts

### Empty canvas

The canvas starts empty every session. Resources appear only when you explicitly place them:

- **Search** for any resource → click a result to pin it on canvas
- **`⇄ N`** button on a node → opens the connection dialog to expand related resources
- **`×`** button on a node → removes it and any resources it was exclusively revealing

Nothing is shown automatically. You build the view you need.

### Node types

Every AWS resource is represented as a node card, colour-coded by category:

| Category | Colour | Examples |
|---|---|---|
| Compute | Blue | ECS service, Lambda, EC2 |
| Network | Slate | ALB, API Gateway, VPC, subnet, SG, Cloud Map |
| Data | Green | RDS, Redshift, DynamoDB, ElastiCache, EFS, S3, OpenSearch |
| Messaging | Purple | SQS, SNS, EventBridge, Kinesis, Firehose, MSK |
| Security | Red | IAM role, Secrets Manager secret, KMS key |
| CI/CD | Pink | CodePipeline, CodeBuild, ECR, Cognito |
| Observability | Amber | CloudWatch alarm, log group |

Node cards show: resource icon, name, type badge, status dot (green/amber/red/gray from live data), and the `⇄ N` connection button.

### Edge types

Nine independent relationship types can be toggled in any combination using the filter bar at the bottom of the screen:

| Type | Colour | What it represents |
|---|---|---|
| **Deployment** | Green | ALB → service, CodePipeline → ECS deploy |
| **Data Flow** | Orange | Service reads secrets, Lambda ← SQS, DynamoDB stream → Lambda, SQS → DLQ |
| **Network** | Slate | SG-based access paths inferred from security group rules |
| **IAM** | Purple | Role assumptions, role → S3/SQS resource access |
| **Observability** | Amber | CloudWatch alarm → monitored resource, alarm → SNS action |
| **Auth** | Pink | API Gateway → Cognito JWT, Lambda REQUEST authorizer |
| **Encryption** | Teal | Resource encrypted with KMS customer key |
| **DNS** | Sky | Cloud Map service discovery registration |
| **Logging** | Gray | ECS container / Lambda → CloudWatch log group |

Hover any filter chip to see a description of what that edge type means.

Enabling a filter is **additive and permanent** within a session — it never auto-disables. When you expand a connection of type X, the X edge filter turns on automatically.

Edges between the same two nodes are separated by a vertical offset so each type is individually clickable. Clicking an edge shows a floating popup with the edge type, direction, and description.

### Expand / collapse

Click `⇄ N` on any node to open the **connection dialog**:

```
← inbound      Edge Type      outbound →
[+ 1]   ●  Deployment       0  [ ]
[ ]     ●  Data Flow         3  [+ 3]
[ ]     ●  Network           2  [+ 2]
[ ]     ●  IAM               1  [+ 1]
```

- **Left `[+ N]`** — expand nodes that have an edge *pointing into* this node
- **Right `[N +]`** — expand nodes that this node points *to*
- Clicking again collapses (hides unless also pinned or held by another expansion)

Newly revealed nodes are placed adjacent to their anchor using a smart positioning algorithm that avoids overlapping existing nodes.

---

## Search

The toolbar search scans **all resources** — including those not yet on canvas. Results appear in a dropdown showing resource icon, name, type, and an `off-canvas` badge for hidden resources.

Selecting a result:
1. Pins the resource permanently on canvas
2. Places it near its nearest visible neighbour (or in a free slot)
3. Selects it and opens the detail panel
4. Animates the viewport to it

---

## Detail panel

Click any node to open the detail panel (right side). Four tabs:

| Tab | Content |
|---|---|
| **Summary** | Key metadata: ARN, cluster, task definition, running/desired count, target health (`2/2 healthy`), subnets, security groups, task role, etc. |
| **Relationships** | All edges grouped by type, showing direction and description |
| **AI Brief** | Structured copy-paste context block for AI assistants — includes all AWS identifiers, relationships, and operational state |
| **Raw JSON** | Full raw snapshot data for the selected resource, with a Copy button |

---

## Snapshot selection

### Single snapshot (default)

The navigator reads `snapshots/latest.json` which points to a snapshot folder. To load a specific snapshot, add `?snapshot=<folder>` to the URL:

```
http://localhost:5173/?snapshot=2020-06-03T10-00-00Z-us-east-2
```

### Snapshot picker

Click the current snapshot label in the top-left toolbar to open a dropdown listing all available snapshots sorted newest-first.

### Snapshot diff (compare two snapshots)

Click the **⇄ compare with…** dropdown (next to the current snapshot) to select a reference snapshot. When set:

- The canvas resets and shows only resources that are **new** (in current, absent from reference) or **modified** (in both but config changed)
- New resources get a `✦ NEW` green badge; modified resources get a `◈ CHANGED` amber badge with a list of what changed
- Resources are arranged in a non-overlapping grid: modified on the left, added on the right
- Individual items can be removed with `×`; the diff resets when you switch the primary snapshot

**Diff detects changes in**: ECS services (new deployment, degraded health), Lambda (runtime, IAM role), RDS (status, instance class), ElastiCache (status), Redshift (node type, count, status), DynamoDB tables, S3 buckets, SQS queues, SNS topics, API Gateway APIs, Cognito pools.

---

## Running against your own snapshots

1. Run the export script from the repo root:
   ```bash
   ./export-infra-snapshot.sh --region <your-region> --profile <your-profile>
   ```
2. Start the navigator dev server:
   ```bash
   cd navigator && npm run dev
   ```
3. The navigator automatically picks up the new snapshot via `snapshots/latest.json`.

---

## Tech stack

| | |
|---|---|
| Framework | React 18 |
| Build | Vite |
| Canvas | `@xyflow/react` v12 (React Flow) |
| Auto-layout | Dagre (left-to-right) |
| Language | TypeScript |
| Styling | Plain CSS |

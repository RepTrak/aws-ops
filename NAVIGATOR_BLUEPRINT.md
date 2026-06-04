# AWS Ops Navigator — Design Blueprint

## Purpose

The navigator is an **infinite-canvas architecture explorer** for exported AWS production snapshots.

It is not a live management console. Its purpose is to help an engineer:

- Build up a working mental map of production infrastructure interactively
- Understand how services relate across network, data, IAM, and operational dimensions simultaneously
- Collect the exact context needed to ask an AI agent to produce safe AWS CLI changes
- Compare two snapshots to understand what changed between deployments or incidents

---

## Core Design Philosophy

### 1. Empty canvas, user-driven exploration

The canvas starts empty on every session. Resources appear only when explicitly placed:
- **Search → click** pins a resource permanently on canvas
- **Expand** a node's connections to reveal related resources
- **`×`** removes a resource and its expansion-only descendants

This prevents information overload and lets each engineer build exactly the view they need.

### 2. High-dimensional relationships, not rigid layers

The original design used three fixed layers (Network / Data Flow / IAM). The built system instead models **nine independent edge types** that can be toggled in any combination simultaneously. The same resource node exists in all dimensions at once; the user controls which relationship types are illuminated.

| Edge Type | Color | What it shows |
|---|---|---|
| Deployment | Green | ALB → service, pipeline → ECS deploy |
| Data Flow | Orange | service reads secrets, Lambda ← SQS, DynamoDB stream → Lambda |
| Network | Slate | SG-based access paths between resources |
| IAM | Purple | role assumptions, role → S3/SQS access |
| Observability | Amber | alarm → monitored resource, alarm → SNS |
| Auth | Pink | API Gateway → Cognito JWT, Lambda authorizer |
| Encryption | Teal | resource encrypted with KMS key |
| DNS | Sky | Cloud Map service discovery registration |
| Logging | Gray | ECS container / Lambda → CloudWatch log group |

Edge filters are **additive and persistent** — enabling a filter never disables it automatically. When a user expands a connection of type X, the X filter is automatically enabled so edges become visible without a manual step.

### 3. Progressive disclosure via expand/collapse

Every visible node shows a **`⇄ N`** button listing its total connection count. Clicking opens a **connection dialog** with one row per edge type:

```
← inbound    Edge Type    outbound →
[+ 1]   ●  Deployment      0  [ ]
[ ]     ●  Data Flow        3  [+ 3]
[ ]     ●  Network          2  [+ 2]
[ ]     ●  IAM              1  [+ 1]
```

- **Left `[+ N]`** reveals nodes that have edges pointing *into* this node
- **Right `[N +]`** reveals nodes this node points *to*
- Each direction can be expanded/collapsed independently
- Collapsing is smart: a node is hidden only if no other active expansion and no pin is keeping it visible

### 4. Parallel edge separation

When multiple edge types connect the same two nodes (common: both a Deployment and a Network edge from an ALB to a service), each type gets a distinct vertical offset so they start and end at different pixel positions and are independently clickable.

---

## Node Model

### Resource categories and visual palette

| Category | Color | Examples |
|---|---|---|
| Compute | Blue | ECS service, Lambda, EC2 |
| Network | Slate | ALB, API Gateway, VPC, subnet, SG, Cloud Map |
| Data | Green | RDS, Redshift, DynamoDB, ElastiCache, OpenSearch, EFS, S3 |
| Messaging | Purple | SQS, SNS, EventBridge, Kinesis, Firehose, MSK, MQ |
| Security | Red | IAM role, Secrets Manager secret, KMS key |
| CI/CD | Pink | CodePipeline, CodeBuild, ECR, Cognito |
| Observability | Amber | CloudWatch alarm, log group |

### Node card anatomy

```
┌──────────────────────────────────────────┐
│  icon  │  label           │  [×]  ● status │
├──────────────────────────────────────────┤
│  type badge           │  ⇄ N connections  │
└──────────────────────────────────────────┘
```

- **`×`** button appears on hover — removes the node and its exclusively-expansion-revealed descendants
- **Status dot** reflects live operational state: green = running/healthy, amber = degraded/warning, red = error/alarm, gray = stopped
- **Target health** is surfaced from ALB target health data and drives the status dot (a service ECS reports as 2/2 running but ALB reports 1/2 healthy correctly shows amber)
- **Diff badges** appear in diff mode: `✦ NEW` (green) for added resources, `◈ CHANGED` (amber) for modified resources with a change list

### Hidden vs visible nodes

Most detail nodes (IAM roles, KMS keys, log groups, secrets, CloudWatch alarms, Cloud Map namespaces) start **hidden** and only appear when expanded. Core resources (ECS services, ALBs, databases, Lambda, API Gateway, S3 buckets) are also hidden by default — the canvas starts empty. The distinction matters for collapse: hidden-by-default nodes hide when collapsed; pinned nodes (user-searched) never auto-hide.

### Node visibility rules (precedence order)

1. **Forced hidden** — user explicitly clicked `×` → stays hidden until reset or re-searched
2. **Pinned** — user searched and clicked the node → always visible
3. **Expansion-revealed** — visible while at least one `nodeId:edgeType:direction` expansion key is active that targets it
4. **Default** — hidden

---

## Search

The toolbar search scans **all nodes** (including off-canvas hidden ones) across label, resource type, and metadata values. Results appear in a styled dropdown showing resource icon, name, type, and an **`off-canvas`** badge for hidden nodes.

Selecting a result:
1. Pins the node (persists across collapses)
2. If hidden: places it adjacent to its nearest visible neighbour using the smart positioning algorithm
3. Selects it (opens detail panel)
4. Flies the viewport to it

---

## Smart Positioning

When nodes are revealed — via search or expand — the positioning algorithm avoids overlap:

- **`findFreeSlot(desired, occupied)`** — searches outward in rectangular rings from a desired position, returning the nearest free slot (each slot = node dimensions + gap margin)
- **`positionSiblings(count, anchor, direction, existing)`** — for expansion siblings, stacks them vertically in a column left (inbound) or right (outbound) of the anchor, each slot tested against existing nodes and previously placed siblings in the same batch

---

## Detail Panel

The right-side panel opens when a node is clicked. Four tabs:

### Summary
Key-value metadata: ARN, cluster, task definition, running/desired count, **target health** (`2/2 healthy`), subnets, security groups, task role, etc.

### Relationships
All edges grouped by type, showing direction (→ outbound, ← inbound) and description.

### AI Brief
A structured, copy-paste ready context block for pasting into Claude or any AI assistant. Includes:
- Resource type and name
- All relevant AWS identifiers
- Relationship summary (connections by type)
- Current operational state
- Snapshot region and timestamp

### Raw JSON
The full raw snapshot data object for the selected resource — useful for debugging and for understanding what the snapshot actually contains. Includes a Copy button.

---

## Edge Info Popup

Clicking any edge (not a node) opens a small floating popup at the cursor position:

```
┌──────────────────────────────────────────┐
│  ●  Data Flow   reads secret          ✕  │
├──────────────────────────────────────────┤
│  🐳 api-service   →   🔑 prod/api/db     │
└──────────────────────────────────────────┘
```

Shows: edge type (colored), description, source icon+name, direction arrow, target icon+name. Closes on outside click or Escape. Positioned near the cursor, clamped to viewport bounds.

---

## Snapshot Management

### Snapshot selector (toolbar, top-left)

The current snapshot is shown as a clickable button next to the brand. Clicking opens a scrollable dropdown listing all available snapshots (fetched from `/snapshots/_list`) sorted newest-first.

Selecting a snapshot:
- Reloads all data
- Resets the canvas to empty
- Updates the URL with `?snapshot=folder` for bookmarkability

### Comparison / Diff mode (second dropdown)

A second dropdown ("⇄ compare with…") selects a reference snapshot. When set:
- Canvas resets
- A diff is computed between the current and reference snapshots
- Only **Added** and **Modified** resources appear on canvas, each with a badge
- Layout: Modified items (left zone), Added items (right zone), arranged in a non-overlapping grid
- `fitView` frames the full diff
- Individual diff nodes can be removed with `×`
- The second dropdown resets to empty whenever the first (current) snapshot changes

#### Diff detection covers

ECS services, Lambda functions, RDS instances, ElastiCache clusters, Redshift clusters, DynamoDB tables, S3 buckets, SQS queues, SNS topics, API Gateway v2 APIs, Cognito user pools.

**Added** = exists in current, absent from reference.
**Modified** = exists in both; detected fields: task definition version, desired/running count, instance class, status, runtime, IAM role.

---

## Snapshot Data Structure

The navigator reads from a snapshot folder produced by `export-infra-snapshot.sh`:

```
snapshots/
  latest.json                    → { "folder": "..." }
  <timestamp>-<region>/
    manifest.json                → region, timestamp, profile
    raw/                         → AWS API responses (JSON + NDJSON)
    derived/                     → pre-computed topology files
```

### Key derived files used by the navigator

| File | Content |
|---|---|
| `service_topology.json` | ECS service → containers, EFS, Cloud Map, subnets, SGs, TGs |
| `alb_to_service.json` | ALB → target groups → ECS services (pre-joined) |
| `sg_connectivity.json` | SG-to-SG inbound edges with ports (network inference) |
| `sg_members.json` | SG → list of member resources (inverse map) |
| `subnet_classification.json` | Subnet → public/private, AZ, CIDR, route table |
| `iam_role_resource_access.json` | Role → `service_access` map (from policy analysis) |
| `iam_role_trust_analysis.json` | Role → trusted services/accounts/federated |
| `cloudwatch_alarm_targets.json` | Alarm → monitored resource + action type |
| `secret_consumers.json` | Secret ARN → task definitions that reference it |
| `kms_usage.json` | KMS key → encrypted resources |
| `pipeline_chains.json` | CodePipeline stages → source/build/deploy references |
| `dynamodb_stream_consumers.json` | DynamoDB stream → Lambda consumers |
| `apigw_auth_chain.json` | API Gateway authorizer → Cognito pool |
| `sqs_dlq_chains.json` | SQS queue → dead-letter queue |
| `task_eni_map.json` | ECS task → ENI → IP, subnet, SGs |
| `vpc_endpoint_routes.json` | VPC endpoint → subnets routed through it |

### Resource classes captured in snapshot

The snapshot covers 50+ AWS service categories including: ECS, ECR, EC2 Auto Scaling, ALB, API Gateway (v1 + v2), CloudFront, WAFv2, ACM, VPC networking, Route53, Route53 Resolver, RDS (with Proxy), Redshift (provisioned + Serverless), DocumentDB, DynamoDB, ElastiCache, MemoryDB, EFS, S3, Lambda, SQS, SNS, EventBridge, Kinesis, Firehose, MSK, MQ, Step Functions, CodeBuild/Pipeline/Deploy, IAM, KMS, CloudTrail, GuardDuty, Security Hub, Access Analyzer, Organizations, Cognito, OpenSearch, CloudWatch (alarms + logs).

---

## Technology Stack

| Concern | Choice |
|---|---|
| Framework | React 18 |
| Build | Vite |
| Graph canvas | `@xyflow/react` v12 (React Flow) |
| Auto-layout | Dagre (LR direction) |
| Language | TypeScript |
| Styling | Plain CSS (no framework) |
| Serving | `npm run dev` (Vite dev server) or `python3 -m http.server` for built output |

### Project structure

```
navigator/
  src/
    types/         snapshot.ts, graph.ts
    lib/           snapshotLoader.ts, graphBuilder.ts, layout.ts
                   colors.ts, aibrief.ts, positioning.ts
                   snapshotDiff.ts, expandContext.ts
    components/
      Canvas.tsx           React Flow canvas wrapper
      DetailPanel.tsx      4-tab detail panel
      Toolbar.tsx          Search + snapshot pickers
      FilterBar.tsx        9 edge type toggles (bottom bar)
      ConnectionDialog.tsx Per-edge-type expand/collapse dialog
      EdgeInfoPopup.tsx    Floating edge click popup
      nodes/ResourceNode.tsx
      edges/RelationshipEdge.tsx
```

---

## UX Principles

1. **Empty canvas, intent-driven** — nothing is shown until the user asks for it
2. **Edges are the primary communication** — relationships matter more than individual resource properties
3. **Progressive disclosure** — expand only what you need; collapse to clean up
4. **No accidental hiding** — pinned nodes survive collapses; `×` is the only way to remove
5. **AI handoff readiness** — every node produces a copy-paste brief with all identifiers an agent needs
6. **Diff is first-class** — comparing two snapshots is a core workflow, not an afterthought
7. **Snapshot is the source of truth** — no live AWS queries; all data is from the point-in-time snapshot

---

## Acceptance Criteria

The navigator is working correctly if:

1. Starting from an empty canvas, a user can search for `api-service`, place it, and within 3 clicks understand: what ALB routes to it, what databases it can reach (via Network expand), what secrets it reads (via Data Flow expand), and what IAM role it uses (via IAM expand).
2. Clicking any edge opens a popup at the cursor showing the correct edge type and direction — even when two edge types connect the same two nodes (they have distinct physical paths due to vertical offset).
3. Selecting a comparison snapshot shows only new and modified resources with visual badges, arranged in a non-overlapping grid.
4. The AI Brief tab for any resource contains enough structured context to paste into an AI assistant and generate correct AWS CLI commands without further lookup.
5. All 9 edge type filter buttons have hover hints explaining what each type means.
6. Snapshot switching updates the URL, resets the canvas, and loads the new data without a page reload.

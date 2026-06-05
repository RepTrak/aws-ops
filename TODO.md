# TODO

Work items, known gaps, and design decisions to revisit.

---

## 1. Missing AWS service coverage

### High priority

| Service | What it adds | Suggested script |
|---|---|---|
| **AWS Backup** | Backup vaults, plans, recovery points — data protection visibility across all resources | `export-scripts/export-backup.sh` |
| **RAM (Resource Access Manager)** | Cross-account shared resources (subnets, TGW, databases) — essential for multi-account topology | `export-scripts/export-ram.sh` |
| **AWS Glue** | ETL jobs, data source connections (RDS/S3/Redshift), crawlers, triggers — data pipeline topology | `export-scripts/export-glue.sh` |

### Medium priority

| Service | What it adds |
|---|---|
| **AppSync** | GraphQL APIs + data source connections (Lambda, DynamoDB, RDS) — different API connectivity pattern |
| **VPC Lattice** | Modern service-to-service networking; service network associations and target groups |
| **AWS X-Ray** | Distributed tracing service map — shows which Lambda/API GW/ECS services trace each other |
| **DataSync** | Data transfer tasks between NFS/EFS/S3 locations |
| **Lambda layers** | Shared dependency topology across Lambda functions |
| **Lambda function URLs** | Public entry points to Lambda (separate from API GW) |
| **EKS add-ons** | VPC CNI, EBS CSI, CoreDNS versions — defines actual cluster networking and storage behaviour |
| **EKS access entries** | IAM-to-Kubernetes RBAC mapping |
| **S3 replication rules** | S3-to-S3 dependency edges (cross-region/cross-account replication) |
| **Classic ELB** | Deprecated but may still exist in older accounts; not currently captured |

### Low priority / niche

Neptune, QLDB, Timestream, Keyspaces, FSx, Storage Gateway, Macie, Inspector v2,
Detective, CodeArtifact, CodeCommit (deprecated), Amplify, IoT Core, SageMaker,
EMR, Athena, Lake Formation, Service Catalog, Control Tower, Lightsail, App Runner,
Elastic Beanstalk, AWS Batch.

---

## 2. Gaps within already-captured services

| Service | Gap | Impact |
|---|---|---|
| **EC2** | Only ECS-tagged instances captured; bare EC2 workloads are invisible | Any workload running directly on EC2 (not via ECS/EKS) is missing |
| **VPC** | Flow log configuration not captured (per-VPC enabled/disabled status) | Can't tell which VPCs have traffic visibility |
| **Route53** | Failover, weighted, geolocation routing policy details not expanded | Advanced traffic routing topology invisible |
| **ECS** | Capacity provider strategy details, task-set deployments not captured | Can't distinguish Fargate vs EC2 launch type at task level |
| **RDS Proxy** | Authentication mode, max connections config not captured | Proxy connection topology incomplete |
| **CloudWatch** | Metric streams, Synthetics canaries, Contributor Insights not captured | Monitoring topology partially visible |

---

## 3. Multi-region support design gap

### Current behaviour

When `--all-regions` is used, the script:

1. Enumerates all opted-in regions via `ec2 describe-regions`, sorted alphabetically
2. Runs a full export (including global services) for the **first region alphabetically**
3. Runs regional-only exports (with `--skip-globals`) for all subsequent regions
4. Creates a **separate timestamped snapshot folder per region**
5. Sets `latest.json` to point at the first region's folder at the end

### Problems

**Global data lands in the wrong region.**
The first region alphabetically (e.g. `ap-east-1`) receives all global data — IAM, Route53,
S3, CloudFront, Organizations — even if your primary infrastructure is in `eu-west-1`.
The `eu-west-1` snapshot will be missing these global resources entirely.

**No cross-region consolidation.**
The navigator loads one snapshot at a time. There is no way to view all regions at once.
Each region's folder is a separate, independent snapshot. To navigate `eu-west-1` resources
you must load that snapshot explicitly (`?snapshot=...`); it won't have IAM or Route53 data.

**`latest.json` points at the alphabetically-first region, not the primary region.**
Anyone loading the navigator after a `--all-regions` run will see the first alphabetical
region's data, which may not be their primary region at all.

### Design options to consider

**Option A — `--primary-region` flag (recommended)**
Add a `--primary-region <region>` flag. When used with `--all-regions`, that region gets
the global data instead of the alphabetically-first one. `latest.json` points at it.

```bash
./export-infra-snapshot.sh --all-regions --primary-region eu-west-1 --profile prod
```

**Option B — Always capture global data in every region**
Remove `--skip-globals` logic entirely. Each region's snapshot is fully self-contained
(includes IAM, Route53, S3, etc.). Costs more API calls and storage but eliminates the
confusion about where global data lives.

**Option C — Consolidated multi-region snapshot folder**
Instead of one folder per region, produce a single snapshot folder with sub-directories:
```
snapshots/2026-06-05T01-00-00Z-all/
  manifest.json          ← lists all regions captured
  global/raw/            ← IAM, Route53, S3, CloudFront, Organizations
  eu-west-1/raw/         ← eu-west-1 regional data
  us-east-1/raw/         ← us-east-1 regional data
  ...
```
Requires significant navigator changes to load and display multi-region data.

**Option D — Status quo, but document it**
Keep current behaviour and document clearly that `--all-regions` is for completeness
auditing, not for the navigator. The navigator is designed for single-region exploration.

---

## 4. Navigator improvements

- **Multi-region view**: currently no way to show resources from two regions simultaneously
- **EKS workload visibility**: pods, deployments, services inside the cluster are invisible
  (would require Kubernetes API access, not just AWS API)
- **RDS reader endpoints**: reader endpoints not shown as separate nodes
- **Lambda aliases**: aliases as separate nodes to show traffic shifting topology

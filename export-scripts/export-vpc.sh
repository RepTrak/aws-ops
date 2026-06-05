#!/usr/bin/env bash
# Networking — VPC, subnets, SGs, route tables, TGW, VPN, Direct Connect
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-vpc.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/ec2-vpcs.json"                          ec2 describe-vpcs
safe_aws_json "${OUT_DIR}/raw/ec2-subnets.json"                       ec2 describe-subnets
safe_aws_json "${OUT_DIR}/raw/ec2-route-tables.json"                  ec2 describe-route-tables
safe_aws_json "${OUT_DIR}/raw/ec2-security-groups.json"               ec2 describe-security-groups
safe_aws_json "${OUT_DIR}/raw/ec2-network-acls.json"                  ec2 describe-network-acls
safe_aws_json "${OUT_DIR}/raw/ec2-internet-gateways.json"             ec2 describe-internet-gateways
safe_aws_json "${OUT_DIR}/raw/ec2-egress-only-internet-gateways.json" ec2 describe-egress-only-internet-gateways
safe_aws_json "${OUT_DIR}/raw/ec2-nat-gateways.json"                  ec2 describe-nat-gateways
safe_aws_json "${OUT_DIR}/raw/ec2-vpc-endpoints.json"                 ec2 describe-vpc-endpoints
safe_aws_json "${OUT_DIR}/raw/ec2-transit-gateways.json"              ec2 describe-transit-gateways
safe_aws_json "${OUT_DIR}/raw/ec2-network-interfaces.json"            ec2 describe-network-interfaces
safe_aws_json "${OUT_DIR}/raw/ec2-prefix-lists.json"                  ec2 describe-managed-prefix-lists
safe_aws_json "${OUT_DIR}/raw/ec2-addresses.json"                     ec2 describe-addresses
safe_aws_json "${OUT_DIR}/raw/ec2-vpc-peering-connections.json"       ec2 describe-vpc-peering-connections
safe_aws_json "${OUT_DIR}/raw/ec2-transit-gateway-attachments.json"   ec2 describe-transit-gateway-attachments
safe_aws_json "${OUT_DIR}/raw/ec2-transit-gateway-route-tables.json"  ec2 describe-transit-gateway-route-tables
safe_aws_json "${OUT_DIR}/raw/ec2-vpn-gateways.json"                  ec2 describe-vpn-gateways
safe_aws_json "${OUT_DIR}/raw/ec2-vpn-connections.json"               ec2 describe-vpn-connections
safe_aws_json "${OUT_DIR}/raw/ec2-customer-gateways.json"             ec2 describe-customer-gateways

safe_aws_json "${OUT_DIR}/raw/directconnect-connections.json"         directconnect describe-connections
safe_aws_json "${OUT_DIR}/raw/directconnect-virtual-interfaces.json"  directconnect describe-virtual-interfaces
safe_aws_json "${OUT_DIR}/raw/directconnect-gateways.json"            directconnect describe-direct-connect-gateways

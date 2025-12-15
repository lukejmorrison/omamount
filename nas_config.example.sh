#!/usr/bin/env bash

# omamount: example configuration (safe to commit)
#
# Copy this file to `nas_config.local.sh` and edit it for your environment.
# This repo intentionally does NOT ship any real IPs, hostnames, or share names.
# Do NOT put credentials in any config file.

# Hostname or IP address of your NAS (hostname recommended if you have local DNS).
NAS_IP="NAS_HOST_OR_IP"

# Where shares should be mounted on this machine.
MOUNT_ROOT="/mnt/nas"

# SMB shares to mount from //NAS_IP/<share> to $MOUNT_ROOT/<share>
SHARES=(
  "share1"
  "share2"
)

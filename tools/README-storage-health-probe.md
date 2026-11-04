# Storage health probe

`storage-health-probe.py` collects read-only ZFS and smartmontools output for storage-health development and fixture testing.

The probe does not modify pools, clear errors, scan storage controllers, start SMART self-tests, or change device power settings.

## Requirements

- Python 3
- OpenZFS utilities
- smartmontools
- root access

## Usage

Discovery without SMART queries:

    python3 tools/storage-health-probe.py --discovery-only --output /root/storage-health-probe-discovery

Normal collection uses `smartctl -n standby -a -j` for ATA devices so a disk already in standby can be skipped rather than awakened:

    python3 tools/storage-health-probe.py --output /root/storage-health-probe

Collect selected devices only:

    python3 tools/storage-health-probe.py --device /dev/sda --device /dev/nvme0 --output /root/storage-health-probe-selected

Establish an initial full SMART baseline:

    python3 tools/storage-health-probe.py --baseline --output /root/storage-health-probe-baseline

Baseline mode may wake sleeping rotational disks. SAS/SCSI and NVMe devices are queried without the ATA-specific `-n standby` option.

## Output and privacy

Output includes ZFS status, smartctl discovery, per-device SMART JSON, timing, exit status, and decoded smartctl exit bits. Device directories use a stable serial or another available identity.

Raw output can contain hostnames, serial numbers, WWNs, device paths, pool names, and controller topology. Review and sanitize fixtures before committing or sharing them publicly.

A nonzero smartctl return code does not always indicate a current failure. Consumers must evaluate decoded exit bits together with protocol-specific SMART data.

## Tested configurations

- ATA SATA SSDs behind Intel AHCI
- SAS HDDs behind LSI SAS2008 HBAs
- NVMe SSDs
- ZFS RAIDZ1 and RAIDZ3
- an ATA historical threshold event
- a SAS drive with grown defects and uncorrected reads
- an online ZFS pool with a nonzero per-vdev READ counter

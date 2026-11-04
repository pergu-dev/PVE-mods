# Storage health fixtures

These curated fixtures are derived from real Proxmox storage configurations.
Only fields required for parser development are retained. Hardware identifiers
are synthetic.

## smart-ata-hdd-healthy.json

Healthy rotational ATA disk queried while active.

Expected interpretation:

- protocol: ATA
- SMART overall health: passed
- no current SMART failure
- power-on age alone is not a warning condition

## smart-sas-uncorrected-read.json

SAS disk whose overall SMART status still reports passed, but which has grown
defects and uncorrected read errors.

Expected interpretation:

- protocol: SCSI
- SMART overall health: passed
- grown defect list: 259
- uncorrected reads: 9
- result requires attention despite the passed overall status

## zpool-online-vdev-read-error.txt

ZFS pool that remains ONLINE and reports no known permanent data errors, while
one leaf vdev has a nonzero READ counter.

Expected interpretation:

- pool state: ONLINE
- per-vdev READ counter: 1
- no known permanent data errors
- result requires attention rather than reporting OK

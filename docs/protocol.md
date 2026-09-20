# Helper commands and backups

Both clients push the same DEX JAR to `/data/local/tmp/sa-unlock-probe.jar` and use:

```sh
CLASSPATH=/data/local/tmp/sa-unlock-probe.jar app_process /system/bin SaProbe ACTION SLOT
```

| Action | Operation |
| --- | --- |
| `state` | Read `isUserFiveGSaEnabled(slot)` and, when available, the network mode. |
| `enable-sa` | Call `setUserFiveGSaEnabled(true, slot)`. |
| `disable-sa` | Call `setUserFiveGSaEnabled(false, slot)`. |

`SLOT` is `0` for SIM 1 or `1` for SIM 2. Both clients require a manual selection; neither detects the carrier or changes the default data SIM. The helper exits nonzero when its main query or write fails. Clients require exactly one matching `STATE slot=N` and one `STATE isUserFiveGSaEnabled=true` or `false` line on stdout. An unavailable network-mode query is informational and does not replace the SA switch check.

For older desktop releases, the helper still accepts `state`, `enable-sa-slot0` and `disable-sa-slot0` without a slot argument. Those commands always target slot 0.

## Storage

Both clients store files under `devices/<hex-utf8-serial>/slot-<0-or-1>/` within the application data directory. Model names are display metadata, not identity keys. Legacy root-level files are moved according to their saved serial and slot; existing destination files are never overwritten. Backups from other devices do not block normal operations.

## Backup fields

`backup.json` and `recovery.json` use the same JSON object:

| Field | Type | Source |
| --- | --- | --- |
| `formatVersion` | integer | `2` for new backups. |
| `slot` | integer | User-selected logical slot: `0` or `1`. |
| `deviceName` | optional string | Readable `ro.product.model`; older files may omit it. |
| `serial` | string | Selected ADB device serial. |
| `savedAt` | string | UTC ISO 8601 timestamp. |
| `visible` | string or null | `system/5g_network_mode_selection_visiable`. |
| `saDisabled` | string or null | `system/5g_sa_mode_disabled`. |
| `fiveGNetworkMode` | string or null | `global/fiveg_network_mode`. |
| `dualSaEnabled` | string or null | `global/dual_sa_enabled`. |
| `saEnabled` | boolean | `isUserFiveGSaEnabled(slot)`. |

An omitted optional Settings field is equivalent to null. Null means the key was unset and must be deleted when restoring; it must not be written as the text `null`. Preserve the boolean type: the JSON string `"false"` is not a valid switch state. Backups contain a device identifier and belong outside source control.

Legacy backups with no `formatVersion` or `slot` are read as slot 0. They restore only the three original Settings values; they do not restore `dual_sa_enabled`, which was not recorded. New backups require version 2 and a valid slot. Older app versions should not be used to restore version 2 backups.

## Operation sequence

1. Require one authorized ADB device, select its slot-specific storage, and check the security-debugging switch before unlocking. A reported `0` stops before snapshots or writes; missing properties proceed to normal permission checks. Push the helper and read the state.
2. Preserve an existing same-device, same-slot original backup; reject a slot mismatch. Otherwise save one before making any changes.
3. Save a separate recovery snapshot for this attempt.
4. Write visibility `1` and SA-disabled `0`, invoke the enable action, then verify the settings and SA switch.
5. On success, remove the recovery snapshot. On failure, restore the attempt snapshot and verify each item. If recovery cannot be verified, keep the snapshot and block mutations for both slots on that phone until recovery completes, because the settings are shared. Other phones remain usable.

Restore prefers a pending recovery snapshot over the original backup. It checks the serial and selected slot, skips writes for values that already match, invokes the saved SA switch state for that slot, restores the saved Settings values, and reads each item back. A failure on one item does not skip the others. Final read-back verification determines recovery success even if an attempted write failed. Unresolved mismatches and read failures retain the recovery file. Keep the original backup after a successful restore.

The private service can use `fiveg_network_mode` for the default data slot and `dual_sa_enabled` for the other slot. New snapshots capture both. These Settings and the two system overrides apply across the phone, even though the API call targets one slot. Keep the same SIM configuration and default data SIM when restoring. Backups identify a device and logical slot, not the individual SIM card. Restore successive operations on different slots of the same phone in reverse order.

The Windows client locks its backup directory for each operation. Both clients bound individual ADB command waits and read stdout/stderr concurrently. Command success and an enabled SA switch do not prove SA network registration.

# Boot evidence: bounded primary-source research

Date: 2026-11-02. Decision: **DENY production admission; evidence collection only.**

## Scope and conclusion

Read only the two requested implementation files and public documentation. No collector execution, local event/CIM queries, tests, builds, installs, app activation, proxy/RunOnce writes, logoff, restart, or commits were performed for this research. This document is the only file written. Other implementation, integration, delivery, and recovery work is outside this review.

The candidate can provide **corroborating evidence for a controlled, explicitly human-performed full Restart**. Microsoft documents Kernel-General 12 as an OS-start event and CIM `LastBootUpTime` as the last OS restart time. Re-finding a previous event with the same record number and XML fingerprint is a useful retained-record check. Those facts do not establish a universal reboot identifier, complete event-log continuity, or a sufficient production admission gate.

Keep class-90 `BootIdentifier` excluded. This investigation found no primary-source contract establishing either per-reboot uniqueness **or its asserted equivalence to the BCD OS-loader identifier**. Do not replace one unsupported interpretation with the other.

Main reports two live read-only collections, 10/10 collector/policy tests, a same-boot denial with latest Kernel-General 12 dated 2026-10-15 and latest Kernel-Boot 27 type 2, and startup guards that deny experimental activation. These are user-supplied results, not executions or independently verified app changes in this research. They support collection/denial behavior, not a successful controlled-Restart comparison. No admission path is endorsed here.

## What the primary sources establish

| Claim | Warranted conclusion | Limit |
| --- | --- | --- |
| Class 90 `BootIdentifier` is unique on each reboot | Not established. The public `NtQuerySystemInformation` reference does not describe this class/field and warns that the function may change or become unavailable. [S1] | Strict size/structure/nonzero checks validate representation, not identity semantics. |
| The returned GUID is the BCD loader identifier | Not established by the sources located. Microsoft documents `{current}` as the current OS boot-application entry and documents BCD GUIDs, but gives no connection here to the proposed NT field. [S2] | An old-looking embedded GUID date, a suggestive name, or a GUID-shaped value is not proof of either interpretation. |
| Kernel-General 12 indicates OS startup | Supported at the event-description level: "The operating system started at system time <Date Time>." [S3] | The cited Server troubleshooting article does not specify the XML `StartTime` field/version contract or Windows 10/11 Fast Startup emission behavior. |
| Kernel-Boot 27 `BootType=0` proves full Restart | No authoritative mapping/contract was located in this bounded search. | Do not treat Microsoft-hosted community event samples as a vendor guarantee; do not substitute unrelated boot-type enums. Even a full/cold-boot classification would not establish user intent. |
| CIM `LastBootUpTime` indicates last OS restart time | Explicitly documented as a read-only datetime: "Date and time the operating system was last restarted." [S4] | No uniqueness, monotonicity, boot-event correlation, or ten-second agreement guarantee is supplied. |
| Windows Restart avoids the Fast Startup shutdown path | Microsoft explains that Fast Startup shutdown hibernates rather than fully shuts down and directs users to choose Restart. [S5] | The cited article concerns Windows 10 update behavior; it is not a complete Windows 10/11 event-provider contract or proof that a particular user performed Restart. |
| Record ID plus XML SHA-256 proves continuity | It checks retention of one record/fingerprint. `EventRecordID` is the number assigned when logged; `ToXml()` returns the event XML. [S6][S7] | Neither source promises an authenticated chain, cross-boot identity, or complete intervening history. Log retention can discard incoming events or overwrite old events. [S8] |

Search scope: the public NT-query reference; Microsoft BCD identifier documentation; Microsoft event-log, CIM, time, and restart references listed below; and Microsoft Learn search for `SystemBootEnvironmentInformation`, `BootIdentifier`, `Kernel-Boot BootType`, and `Kernel-General StartTime`. The first two exact-term searches returned no results. The Kernel-Boot search surfaced community reports, not a provider contract. This is a bounded **not-established** result, not a claim that no relevant source exists anywhere. No secondary reverse-engineering claim is promoted to a Microsoft guarantee.

## Ordered implementation findings

These are limits on a future admission claim, not claims that the current denied prototype already enables the resident. References describe the inspected snapshot; Main is editing concurrently.

### 1. High: the full-Restart classification is not source-validated

`D:\clash-kuro\apps\desktop\src\main\platform\migration-boot.ts:59`

The verifier requires the string `BootType === '0'` and uses the diagnostic "Full restart not verified; logoff, sleep and fast startup do not qualify." The research did not locate the underlying Microsoft mapping or a supported-client provider/schema contract. Kernel-General 12 and CIM supply startup/restart-time corroboration, not the missing meaning of this numeric field. A passing check must not be described as vendor-proven exclusion of every other transition. [S3][S4]

Needed before admission: establish the actual provider/version semantics on the supported Windows builds, preserve the supporting evidence, and validate the controlled full-Restart comparison. Tests using constructed `BootType` strings verify policy implementation, not Windows semantics. If that contract/evidence remains insufficient, retain denial rather than infer success.

### 2. High: independently selected events are not bound to one boot

`D:\clash-kuro\apps\desktop\scripts\collect-migration-evidence.ps1:18`

`D:\clash-kuro\apps\desktop\src\main\platform\migration-boot.ts:59`

The collector independently selects the newest System event, newest Kernel-General 12, and newest Kernel-Boot 27. `Get-WinEvent` documents newest-to-oldest default ordering, not an atomic snapshot or shared boot association. [S9] The verifier checks that both selected boot-related records exceed the previous checkpoint, but checks time agreement only between Kernel-General `StartTime` and CIM. It never correlates Kernel-Boot 27's event time to that pair.

Thus the implementation does not establish that the selected boot-type event describes the same startup as the selected kernel/CIM values, especially across multiple transitions or missing/delayed provider records. This is a missing proof obligation, not a demonstrated false admission on Windows. Higher record numbers and selecting each provider's latest event do not themselves supply a boot-session identity. The returned `record:digest` is an application token for the chosen event, not a documented OS reboot ID.

Needed before admission: bounded, reviewable same-transition correlation and an explicit refusal for ambiguous/multiple-transition evidence. A single retained checkpoint is not a substitute for that association. No particular correlation field is asserted to be populated or sufficient here.

### 3. Medium: wall-clock ordering and the ten-second tolerance are heuristics

`D:\clash-kuro\apps\desktop\src\main\platform\migration-boot.ts:62`

The code requires the kernel start time to lie after the previous collection and no later than the current collection, requires a different CIM timestamp, and allows at most 10,000 ms between kernel/CIM times. No located source guarantees that tolerance. Microsoft explicitly states that system time can be adjusted forward or backward. [S10]

These checks can conservatively reject inconsistent data, but wall-clock equality/difference is not an independently guaranteed reboot identity. Clock corrections can also cause legitimate controlled restarts to be denied. Do not widen the window or silently accept missing timestamps to obtain a pass; retain denial and resolve the inconsistency. Local measurements can characterize a supported configuration but cannot turn this heuristic into a universal Windows contract.

### 4. Medium: a retained XML fingerprint proves less than complete continuity

`D:\clash-kuro\apps\desktop\scripts\collect-migration-evidence.ps1:12`

`D:\clash-kuro\apps\desktop\scripts\collect-migration-evidence.ps1:23`

`D:\clash-kuro\apps\desktop\src\main\platform\migration-boot.ts:57`

The post-restart query re-finds the prior newest record and compares its SHA-256 with the prepared value. Warranted wording: "the checkpoint record remains retrievable with the same XML fingerprint," assuming the prepared evidence itself is trusted. Not warranted: "the entire System log is continuous," "no events were lost," "the log was never replaced," or "the restart is authenticated." Event-log capacity/retention can discard records, and the documented record number is not a cryptographic chain. [S6][S8]

`ToXml()` promises XML representing event properties, not canonical byte serialization across implementations/builds. [S7] Exact-byte hashing is useful as a conservative comparison, but byte stability was not established; a representation change can safely cause a false denial. A hash alone does not authenticate its input or establish machine identity. Do not broaden this bounded prototype into a hostile-administrator security claim.

### 5. Medium: the output does not preserve the original event XML or semantic envelope

`D:\clash-kuro\apps\desktop\scripts\collect-migration-evidence.ps1:5`

`D:\clash-kuro\apps\desktop\src\main\platform\migration-boot.ts:18`

Each output event contains only record number, digest, and selected EventData fields. Original XML, provider GUID/name, event ID/version, channel, computer, and `TimeCreated` are not returned as reviewable metadata. These system properties exist in the documented event schema. [S11] Provider/ID filters constrain collection, but the parser cannot independently verify that provenance from this output; it validates shapes and field values, not the source event envelope.

Distinguish "preserved XML hash/record" from "preserved XML": the former is implemented by the output; the latter is not. A later human evidence review cannot reconstruct or independently re-hash the original XML from this JSON alone. Credible comparisons need reviewable source evidence and provenance, with storage/handling decided by Main; no artifact location or new script switch is proposed here.

## What is already warranted by static inspection

- The PowerShell collector shown uses event/CIM, current-user identity, registry, and process reads. It contains no proxy or RunOnce mutation, app activation, restart, or logoff command. The TypeScript wrapper invokes this collector; it does not itself establish production admission. This is a statement about the two inspected files, not an audit of their transitive callers.
- PowerShell errors are terminating under the configured policy and reach the error/exit path. The parser rejects malformed identity/timestamps, unsafe record numbers, malformed digests, and inconsistent inventory. The verifier rejects changed SID, a missing/mismatched checkpoint, non-new event records, unchanged kernel digest, nonzero/missing boot type, and inconsistent times. These are useful fail-closed branches, not evidence that all valid Windows histories are classified correctly.
- Sequential collection can observe changing log contents; the `newest.record` inventory check can reject a race rather than falsely call that snapshot consistent. No claim of an atomic snapshot is warranted.
- Current-user SID equality is an account consistency check, not a machine/boot identifier. The process-name inventory is explicitly a known-writer screen, not proof of absence of every writer. Neither check strengthens undocumented boot semantics into a guarantee.

## Bounded HITL conclusion and remaining gates

This is a list of evidence obligations, **not an executable or verified migration procedure**. There is no approved enable command here.

1. Before any future attempt, keep admission and automatic activation denied. Preserve the prepared evidence and an unambiguous record of the user's controlled Restart decision. Evidence must remain bound to the intended machine/account and migration attempt; timestamp/GUID shape alone does not supply that binding.
2. The human explicitly chooses a full **Restart**. Do not substitute shutdown/power-on with Fast Startup, logoff/logon, sleep, or hibernation. No agent-triggered restart and no automatic enable are authorized. [S5]
3. After that Restart, an ordinary-user read-only comparison must preserve reviewable before/after evidence, demonstrate the retained checkpoint, explain provider/version semantics, correlate the boot events with CIM for the same transition, and resolve clock or log ambiguities. Restart observation is a controlled operational premise; this bundle corroborates it rather than independently proving user intent.
4. Continue to deny on inaccessible/missing evidence, unsupported schema/type, missing or mismatched checkpoint, stale/same-boot data, ambiguous event association, multiple unexplained transitions, clock inconsistency, or unvalidated supported-build semantics. Never elevate, reset logs, alter clocks, weaken checks, or fall back to class-90 GUIDs just to obtain acceptance.
5. A real controlled-Restart comparison and supported-client coverage remain unverified by this research. Main's reported same-boot denial and test passes do not close those gaps. Boot corroboration also does not prove that competing writers cannot start later or that ownership handoff/recovery is complete; those remain separate delivery obligations outside this review.

**Bottom line:** defensible as a tentative read-only continuity/corroboration bundle for a human-controlled restart, with explicit limitations. Not yet defensible as universal boot identity or sufficient production admission evidence. Production gate remains denied until those evidence obligations are credibly met and separately reviewed.

## Primary sources read

All sources accessed 2026-11-02. Source conclusions are limited to the cited material, not undocumented provider behavior.

- [S1: NtQuerySystemInformation](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation): public selected-class reference and compatibility warning; no `BootIdentifier`/`SystemBootEnvironmentInformation` description located.
- [S2: Boot Options Identifiers](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/boot-options-identifiers): BCD GUIDs and the meaning of `{current}`; no link to the proposed NT field.
- [S3: Troubleshoot unexpected reboots using System event logs](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-unexpected-reboots-system-event-logs): Kernel-General 12 startup description; advises filtering the relevant provider; does not publish the requested client field contract.
- [S4: Win32_OperatingSystem](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem): `LastBootUpTime` definition and read-only datetime type.
- [S5: Updates may not install with Fast Startup in Windows 10](https://learn.microsoft.com/en-us/troubleshoot/windows-client/deployment/updates-not-install-with-fast-startup): hibernating shutdown behavior and explicit Restart instruction.
- [S6: EventRecordID element](https://learn.microsoft.com/en-us/windows/win32/wes/eventschema-eventrecordid-systempropertiestype-element): assigned event record number, `unsignedLong` schema type.
- [S7: EventRecord.ToXml](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.eventing.reader.eventrecord.toxml?view=windowsdesktop-9.0): event XML representation containing event properties, conforming to the event schema.
- [S8: wevtutil reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wevtutil): retention/full-log modes can discard incoming events or overwrite oldest events; logs can be cleared. Read as documentation only; no commands executed.
- [S9: Get-WinEvent](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-7.5): newest-to-oldest default ordering, filtering, possible non-administrator access failures. This is the current PowerShell reference, not proof of all Windows PowerShell 5.1/provider behavior used by `powershell.exe`.
- [S10: System Time](https://learn.microsoft.com/en-us/windows/win32/sysinfo/system-time): system time can be adjusted forward or backward; not an elapsed-time ordering guarantee.
- [S11: SystemPropertiesType](https://learn.microsoft.com/en-us/windows/win32/wes/eventschema-systempropertiestype-complextype): provider/event identity, version, time, record number, channel, computer, and optional correlation properties. Existence in the schema does not guarantee that a usable boot correlation ID is emitted.

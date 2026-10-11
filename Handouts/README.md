# Handouts

Reference material for [Pick Your Poison: Choosing the Right Edition of SQL Server](https://csmore.info/on/editions).

Everything here is written to stand on its own, so you can hand it to someone who was
not in the room.

**Accurate as of:** _[fill in before delivery]_

---

## Start here

**"We are planning a new deployment and need to pick an edition."**
→ [`decision-guide.md`](decision-guide.md). Work the seven questions in order. The
flowchart is the one-page version.

**"We are on SQL Server 2022 and want to know what 2025 changes for us."**
→ [`edition-comparison-2022-to-2025.md`](edition-comparison-2022-to-2025.md). The short
answer is: capacity went up, Resource Governor moved to Standard, reporting rights
changed significantly, and the feature matrix barely moved.

**"We think we are overpaying for Enterprise."**
→ For one instance, run [`../Scripts/02 - Estate Audit and Compliance.sql`](../Scripts/02%20-%20Estate%20Audit%20and%20Compliance.sql).
For a whole estate, run [`../Scripts/Estate/Invoke-SqlEditionAudit.ps1`](../Scripts/Estate/Invoke-SqlEditionAudit.ps1)
and start with the **Opportunity** findings. Then read the downgrade pre-flight in
[`edition-change-runbooks.md`](edition-change-runbooks.md). Do not skip the second step.

**"We have an audit coming."**
→ [`licensing-compliance-checklist.md`](licensing-compliance-checklist.md), section 6.
Start with the passive replica trap in section 2 — it is the most common finding.
Run the estate audit and work the **Licensing** and **Compliance** findings.

**"We need to move between editions."**
→ [`edition-change-runbooks.md`](edition-change-runbooks.md). Upgrading is in place.
Downgrading is a rebuild.

---

## Contents

| File | What it covers |
|---|---|
| [`decision-guide.md`](decision-guide.md) | The seven questions, the flowchart, AHB conversion ratios, common mistakes |
| [`edition-comparison-2022-to-2025.md`](edition-comparison-2022-to-2025.md) | Every 2022→2025 delta, what stayed Enterprise-only, the footnote limits |
| [`licensing-compliance-checklist.md`](licensing-compliance-checklist.md) | Core counting, passive replicas, virtualization, license type, audit prep |
| [`edition-change-runbooks.md`](edition-change-runbooks.md) | Upgrade and downgrade procedures, and the pre-flight that actually matters |

Scripts live in [`../Scripts`](../Scripts) rather than being duplicated here.

| Script | What it does |
|---|---|
| `01 - Edition and Capacity Discovery.sql` | What edition am I on, which caps bind, what is persisted |
| `02 - Estate Audit and Compliance.sql` | Estate inventory, feature usage, headroom, licensing exposure |
| `03 - The Downgrade Reality Check.sql` | Demonstrates why the DMV's blockers are not blockers, and what actually breaks instead |
| `Estate/Invoke-SqlEditionAudit.ps1` | Runs the audit across many instances via dbatools; writes CSVs and a graded findings list |

---

## The three things worth remembering

1. **2025 Standard gained capacity and Resource Governor. It did not gain availability
   groups.** If HA was your reason for Enterprise, nothing changed.

2. **Your license type is now a second axis alongside your edition.** Two shops both
   running Enterprise 2025 can have different feature sets depending on whether they
   carry Software Assurance.

3. **`sys.dm_db_persisted_sku_features` answers "will it restore," not "will it work."**
   It over-reports: on 2025 it still flags partitioning, compression, columnstore,
   In-Memory OLTP and CDC, none of which block a move to Standard. And the things that
   genuinely break — capacity, availability groups, online index maintenance, batch mode
   parallelism — are not persisted anywhere it can see. Rows are not blockers, and zero
   rows are not permission.

---

## A note on shelf life

Licensing terms change monthly and the
[Microsoft Product Terms](https://www.microsoft.com/licensing/terms/) are the
authority. Nothing here is legal advice and I am not a licensing representative.
Confirm with your licensing partner before making a purchasing decision.

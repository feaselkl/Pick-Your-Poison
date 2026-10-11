# SQL Server Licensing Compliance Checklist

Companion reference for [Pick Your Poison: Choosing the Right Edition of SQL Server](https://csmore.info/on/editions).

**This is not legal advice and I am not a licensing representative.** The
[Microsoft Product Terms](https://www.microsoft.com/licensing/terms/) are the
authority and they change regularly. Use this to find questions worth asking, then
confirm the answers with your licensing partner.

**Accurate as of:** _2026-10-10_

---

## 1. Counting cores

- [ ] **Four-core minimum per operating system environment.** A two-vCPU VM still costs four core licenses.
- [ ] **Physical deployments:** count physical cores per socket. Hyperthreading does *not* increase the count.
- [ ] **Virtual deployments:** count virtual cores (logical processors) assigned to the VM. Hyperthreading *does* count here.
- [ ] **Containers** follow the virtual-core rules.
- [ ] Core licenses are sold in **two-core packs**; odd counts round up.
- [ ] Run the counting-inputs query in `Scripts/02 - Estate Audit and Compliance.sql` to establish physical-versus-virtual before counting anything.

**Enterprise under Server + CAL:** capped at 20 cores per instance, and **not
available for new agreements**. If you are still on this, you are grandfathered.
Confirm what happens at your next renewal.

---

## 2. The passive replica trap

This is the one that shows up in audits.

- [ ] Inventory every secondary: AG replicas, FCI passive nodes, log shipping targets, and DR standbys.
- [ ] For each one, confirm **active Software Assurance or a SQL Server subscription**. The free passive secondary benefit requires it. A perpetual license alone does not include it.
- [ ] **A readable secondary is a licensed secondary.** Full stop. If `secondary_role_allow_connections` is anything other than `NO`, that replica needs its own license regardless of SA status.
- [ ] Watch for accidental readability — someone enabling read-intent routing for a reporting workload converts a free passive replica into a billable one.
- [ ] Backups taken on a secondary count as workload. Confirm this is covered.

> On **pay-as-you-go on Linux**, automatic passive-instance detection is not
> available. Every instance bills as active whether or not it is doing work.

---

## 3. Virtualization

- [ ] **Unlimited virtualization requires Enterprise *plus* Software Assurance.** Enterprise alone does not grant it.
- [ ] Licensing by physical host with unlimited virtualization means every VM on that host is covered, but only while SA is current. Lapsed SA does not grandfather the benefit.
- [ ] If you license individual VMs instead, the four-core minimum applies per VM.
- [ ] **Flexible Virtualization Benefit** (running on an authorized outsourcer's hardware) requires SA or a subscription.
- [ ] VM mobility across hosts within a server farm requires SA. Without it, license reassignment is limited to once every 90 days.

---

## 4. License type, not just edition

New in the 2025 era: your license type gates features independently of your edition.
Two shops both running Enterprise can have different capabilities.

Requires **SA or a SQL Server subscription** (via Azure Arc):

- [ ] Best Practices Assessment
- [ ] Point-in-time restore
- [ ] Automated backups to local storage
- [ ] Automatic updates
- [ ] Monitoring and client connection summary
- [ ] Extended Security Update subscription

Available with **license only**:

- Azure Arc onboarding and inventory
- Migration readiness assessment and database migration
- Microsoft Entra authentication
- Microsoft Defender for Cloud, Microsoft Purview
- Failover cluster instance and availability group management

Licensing benefits requiring **SA or subscription**:

- [ ] Free new version upgrades
- [ ] HA/DR passive replica benefit
- [ ] Unlimited virtualization with Enterprise
- [ ] Option to license by virtual machine
- [ ] 180-day dual-use benefit

---

## 5. Non-production environments

- [ ] Dev/test instances should be **Enterprise Developer** or **Standard Developer**. Both are free and may only run outside of production use.
- [ ] **Standard Developer is new in 2025.** If you are certifying an application against Standard, use it. Before 2025 there was no free way to do this.
- [ ] Audit for **Developer edition running production workloads**. This is a licensing violation and it is easy to drift into, such as a "temporary" dev box that started serving producion data to end users.
- [ ] Evaluation edition expires after **180 days** and the instance stops. Know where yours are before they stop for you.
- [ ] Confirm that "non-production" matches Microsoft's definition, not your org chart. A UAT environment that real users depend on may not qualify.

---

## 6. Before an audit

- [ ] Run `Scripts/02 - Estate Audit and Compliance.sql` across the estate and keep the output.
- [ ] Reconcile the instance inventory against purchased licenses, by edition and core count.
- [ ] Document the SA or subscription status for every instance, not just the primaries.
- [ ] Identify every Developer and Evaluation instance and confirm its workload is genuinely non-production.
- [ ] Record the physical-versus-virtual counting basis for each host.
- [ ] Note any instance where the edition exceeds what the workload uses. This is a cost-reduction opportunity, and it is better to find it yourself.

---

## 7. Questions worth asking your licensing partner

1. What exactly does our SA cover, and when does it renew?
2. Are our passive replicas covered under the HA/DR benefit today?
3. Would a SQL Server subscription cost less than our current SA renewal?
4. Does pay-as-you-go through Azure Arc make sense for our variable workloads?
5. What would Azure Hybrid Benefit convert our existing licenses into?
6. Are we grandfathered on anything that will not survive our next renewal?

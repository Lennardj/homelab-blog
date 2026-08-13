# lennardjohn.org — Platform Technical Requirements

**Status:** Draft for review. Nothing here is built yet.
**Date:** 2026-08-13
**Prerequisite completed:** Phase 1 — root domain serves WordPress (commit `87befd9`)

---

## 1. What the platform has to do

| # | Capability | Notes |
|---|---|---|
| R1 | Landing page: about me, teaching experience, technical expertise | Marketing surface, tabs linking to everything below |
| R2 | Learning platform (LMS) with free courses | Open enrolment, no payment |
| R3 | LMS with **paid** courses | Students pay to enrol |
| R4 | CRM tracking students who sign up | Segmentation, contact history, email |
| R5 | Course authoring | Build course content in the platform |
| R6 | Summer/holiday tech camp signup | **Class-based**, see R7–R9 |
| R7 | Camp classes defined by date range + time slot | e.g. 3 classes, morning 09:00–12:00, afternoon 13:00–16:00 |
| R8 | Per-class capacity cap (28–30) that hard-stops signups | Must not oversell |
| R9 | When a class is full → offer "email me" instead of blocking silently | Waitlist / overflow contact |
| R10 | Camp payment | Parents pay for camp place |
| R11 | Online resume | React-based (Reactive Resume) |

---

## 2. The single most important finding

**Tutor LMS gates all monetisation behind Pro.** Per the [official free-vs-pro page](https://tutorlms.com/free-vs-pro/), the free version includes unlimited courses, students, quizzes and instructor dashboards — but *single course selling*, *WooCommerce integration*, *subscriptions* and *memberships* are Pro-only, starting at **$199/year** (lifetime from $499).

This is not specific to Tutor. Reviews of the category note that every major LMS either gates payments behind a paid tier or requires WooCommerce layered on top — LifterLMS, Sensei ($179/yr) and Tutor all follow this pattern.

**Consequence:** R3 (paid courses) cannot be met on free plugins alone. This is a real recurring cost, not a one-off. It needs a decision before anything is built.

> ⚠️ Note on conflicting sources: some third-party articles claim Tutor LMS Free includes WooCommerce monetisation. The vendor's own comparison page says otherwise. **Verify against a live install before purchasing** — install the free plugin and check whether a price field appears.

---

## 3. Component decisions

### 3.1 LMS — Tutor LMS

Meets R2, R5. Meets R3 only with Pro.

Free tier confirmed to include: unlimited courses/lessons/students, quizzes, video (native/YouTube/Vimeo), student + instructor dashboards, course reviews, course preview.
Pro adds: WooCommerce selling, certificates, drip content, prerequisites, assignments, advanced quizzes, reports/analytics.

**Relevant to the camp:** Tutor has a *Maximum Students* setting per course (`0` = unlimited), available in the free version. This caps enrolment — but it has no concept of dates, time slots, or waitlists. **It does not solve R7–R9.**

### 3.2 Camp signup — this is an events problem, not an LMS problem

R7–R9 describe *sessions with schedules and capacity*, which is an event-ticketing model, not a course model. A course has no start time, no morning/afternoon variant, and no waitlist.

Candidate: **Eventin** — integrates with WooCommerce in its free version for ticket sales; Pro from **$79/yr** (lifetime from $119) adds recurring events and additional gateways.

> ⚠️ **Unverified:** I could not confirm from vendor documentation which tier includes *waitlist* and *hard capacity cutoff*. Several competing plugins place waitlists in premium tiers. This must be confirmed on a trial install before committing — it is a core requirement (R8/R9), not a nice-to-have.

Alternatives to evaluate in the same trial: Mage EventPress/Evently (supports multiple dates per event with customer date selection, and conditional fields such as "school name" only for child tickets — directly relevant to camp registration), and FooEvents.

### 3.3 CRM — FluentCRM

Meets R4. Self-hosted WordPress plugin — no external SaaS, all student data stays on your server, which matches the homelab philosophy and avoids sending minors' data to a third party.

Has a **native Tutor LMS integration**: assign default list/tag/status to LMS students, and trigger automations on course enrolment, lesson completion and course completion.

> ⚠️ **Unverified:** free-vs-Pro split for FluentCRM automations. Confirm before relying on automation features.

### 3.4 Payments — WooCommerce + Stripe

Meets R3, R10. Stripe operates in New Zealand and publishes a free official WooCommerce gateway plugin. Supports cards, Google Pay, Apple Pay.

Requirements: a verified Stripe **business account** with business and banking details, HTTPS (already satisfied), and webhooks configured for real-time payment updates.

**PCI scope:** using Stripe's hosted checkout/redirect means Stripe handles card data and you complete a short annual self-assessment (SAQ-A) rather than full PCI certification. **Do not** build a custom card form — that changes your compliance obligations substantially.

### 3.5 Resume — Reactive Resume

**Correction to my earlier estimate.** I previously said self-hosting needs Postgres + MinIO + a headless Chrome sidecar at ~1–1.5Gi. That is now out of date: **from v5.1.0 onwards PDF generation runs client-side via `@react-pdf/renderer`, so Browserless/Chromium is no longer a dependency.**

Current requirement is the app container + PostgreSQL + storage, and storage can be local persistent volume (`/app/data`) instead of MinIO. That is 2 containers, not 4 — materially cheaper than I first told you, and it makes self-hosting at `resume.lennardjohn.org` a reasonable Phase 6 rather than a project of its own.

---

## 4. Infrastructure requirements

### 4.1 Memory — current limits are too low

WooCommerce needs **256–512MB PHP memory**; LMS plugins need 256MB or higher. WordPress defaults to 40MB.

| Workload | Current limit | Required |
|---|---|---|
| `wordpress` container | **512Mi** | **1–1.5Gi** (PHP limit 512M + Apache overhead) |
| `mariadb` container | **512Mi** | **1Gi** |

Two separate settings must both be raised — the PHP `memory_limit` *inside* the container, and the Kubernetes container limit. Raising only one produces confusing failures: WooCommerce reporting a low memory limit while the pod has headroom, or the pod being OOMKilled while PHP thinks it is fine.

Given the cluster's history of OOM on worker nodes (commits `increase memory size on worker nodes`, `i increase the memory on node now monitor pods just crash`), **confirm node headroom before raising limits.**

### 4.2 Storage — this is the biggest technical risk

`wordpress-pvc` and `mariadb-pvc` are **8Gi each on `local-path`**. The local-path provisioner writes to a directory on a **single node** with no replication. If that node's disk fails, the data is gone.

That is acceptable for a blog. It is **not** acceptable for a system holding paid enrolments and children's registration details.

Required before taking real money:
- `mysqldump` CronJob on a schedule, written **off-cluster**
- WordPress PVC backup (uploads, plugins, themes)
- A **restore test** — an untested backup is not a backup
- Consider migrating off `local-path` to replicated storage (Longhorn) or accept node-failure risk explicitly

This is the same class of gap as Incident #23 and the WordPress-content gap noted in the Phase 1 write-up: **Argo CD reconciles declarations, not data.** Git holds the manifests; it holds no course, student, or order.

### 4.3 Transactional email

Camp confirmations, receipts, enrolment emails and "class is full" messages must reach parents' inboxes.

The cluster currently uses Gmail SMTP with an app password for Alertmanager. **Reusing that for customer email is a mistake:** Gmail enforces daily sending limits, and mail sent from a personal Gmail account on behalf of a domain has poor deliverability — receipts landing in spam is a support problem with paying customers.

Requirement: a transactional email provider (Postmark, SendGrid, Amazon SES, Brevo) with SPF, DKIM and DMARC records on `lennardjohn.org`. DNS is already Cloudflare-managed via Terraform, so the records fit the existing IaC pattern.

### 4.4 Performance

WooCommerce + LMS + CRM on one WordPress instance is a heavy install. Recommended: Redis object cache (adds a small Redis pod), and note that WooCommerce/LMS pages are largely uncacheable at the page level because they are per-user.

### 4.5 Availability

Everything runs through one Cloudflare tunnel to a homelab on a residential connection. Once parents are paying, a power cut or ISP outage during a signup window is a business problem, not a hobby inconvenience. Decide consciously what uptime you are promising — or take camp payments through a hosted checkout that works independently of your cluster.

---

## 5. Compliance and safeguarding

You will be storing **personal data about children** and taking payments from their parents. This is a materially higher obligation than a blog.

- **NZ Privacy Act 2020** — collect only what is needed, state why, keep it secure, allow correction/deletion. A privacy policy is required.
- **Parental consent** — the registering adult must be the parent/guardian; capture consent explicitly.
- **Data minimisation** — collect the child's name, age/school, emergency contact and medical/allergy notes only if operationally necessary. Medical information is sensitive data and raises the security bar.
- **Retention** — delete camp registrations after the camp, do not accumulate them indefinitely.
- **Access control** — camp registration lists must not be publicly enumerable. Verify no plugin exposes them via REST API or a public export URL.
- **PCI** — SAQ-A only if you never touch card data (see 3.4).
- **Refund/cancellation terms** — published before taking payment.

This is not legal advice; for the safeguarding and privacy specifics of running a children's camp in NZ you should get a second opinion from someone qualified.

---

## 6. Recommended build order

**Phase 0 — ✅ Done 2026-08-13.** restic over SFTP to a dedicated `resticbackup` user on the Proxmox host; nightly `mariadb-dump` + WordPress PVC, encrypted client-side, 7/4/6 retention, nightly integrity check. **Restore drill verified** — table and post counts matched. See `KNOWLEDGE_BASE.md` §16 and Incident #25.
*Outstanding: a second off-site repository (Cloudflare R2) for true disaster recovery, and a Prometheus alert on backup job failure.*

**Phase 1 — ✅ Done.** Root domain serves WordPress.

**Phase 2 — ✅ Done 2026-08-14.** WordPress and MariaDB container limits raised to 1Gi, PHP `memory_limit` to 512M via ConfigMap, plus `WP_MEMORY_LIMIT`/`WP_MAX_MEMORY_LIMIT`. Sized against measured usage (wordpress 112Mi, mariadb 146Mi, ~1.4Gi free per node; the two pods sit on different workers). Verified in-container. Surfaced and fixed a latent MariaDB `RollingUpdate` deadlock — see Incident #26.

**Phase 3 — ✅ Done 2026-08-14.** Landing, About, Projects, Now published, plus Learn / Tech Camp / Resume placeholders so navigation is not broken. Content version-controlled in `wordpress-content/` as Gutenberg block markup, applied by the idempotent `scripts/wp-bootstrap.sh`. Elementor was evaluated and rejected — it stores designs as opaque serialized JSON, unsuitable for programmatic editing. A WP-CLI runner pod (`wpcli`) was added to the cluster, and the stale `blog.lennardjohn.org` values were cleaned out of the database.
*Outstanding: personal background detail (employment history, qualifications, camp specifics) — deliberately not written, since inventing biography is not something the tooling can do for you.*

**Phase 4 — LMS, free courses only (R2, R5).** Tutor LMS free. Validates the whole model before spending anything.
*Est. 1–2 days setup, plus content authoring time.*

**Phase 5 — Transactional email.** SPF/DKIM/DMARC + provider. Must precede anything that emails customers.
*Est. half day.*

**Phase 6 — Payments (R3, R10).** Stripe account verification, WooCommerce, Tutor LMS Pro. Blocked on the licensing decision in §2.
*Est. 1–2 days + Stripe verification lead time (external, can take days).*

**Phase 7 — Camp signup (R6–R9).** Trial the event plugins first and confirm capacity + waitlist behaviour before building. Highest-uncertainty phase.
*Est. 2–4 days depending on plugin fit.*

**Phase 8 — CRM (R4).** FluentCRM + Tutor LMS integration.
*Est. 1 day.*

**Phase 9 — Resume (R11).** Reactive Resume at `resume.lennardjohn.org`, or a WordPress page if you want it sooner.
*Est. 1–2 days self-hosted.*

---

## 7. Indicative recurring cost

| Item | Cost | Required for |
|---|---|---|
| Tutor LMS Pro | $199/yr (or $499 lifetime) | Paid courses (R3) |
| Eventin Pro | $79/yr (or $119 lifetime) — **if** waitlist is Pro-gated | Camp (R8/R9) |
| Stripe | ~2.7–2.9% + fixed fee per transaction | R3, R10 |
| Transactional email | $0–15/mo | Receipts, confirmations |
| FluentCRM | Free core; Pro cost unverified | R4 |

**Roughly $280/yr in licences before transaction fees**, assuming both Pro tiers prove necessary. Lifetime licences are worth considering given this is a long-lived personal platform.

---

## 8. Decisions needed before building

1. **Pay for Tutor LMS Pro, or switch LMS?** Nothing in R3 is achievable on free plugins.
2. **Annual or lifetime licences?**
3. **Does the camp need online payment at signup, or is a deposit/invoice acceptable?** Deferring payment removes Stripe from the camp critical path entirely.
4. **What is the node-failure tolerance for paid data?** Determines whether `local-path` stays or Longhorn goes in.
5. **What child data is actually collected?** Drives the privacy and security requirements.
6. **Resume: self-hosted Reactive Resume, or a WordPress page first?**

---

## 9. Sources

- [Tutor LMS — Free vs Pro](https://tutorlms.com/free-vs-pro/)
- [Tutor LMS pricing overview](https://elearningindustry.com/directory/elearning-software/tutor-lms/pricing)
- [Tutor LMS course settings (Maximum Students)](https://docs.themeum.com/tutor-lms/course-builder/course-creation/basic/)
- [FluentCRM — Tutor LMS integration](https://fluentcrm.com/docs/tutorlms-integration-with-fluentcrm/)
- [Tutor LMS + FluentCRM](https://tutorlms.com/integration/fluentcrm/)
- [Eventin pricing](https://themewinter.com/eventin/pricing/)
- [Eventin event registration](https://themewinter.com/wordpress-event-registration-plugin/)
- [Mage EventPress / Evently](https://wordpress.org/plugins/mage-eventpress/)
- [Stripe — accepting credit cards in New Zealand](https://stripe.com/resources/more/how-to-accept-credit-cards-in-new-zealand)
- [WooCommerce Stripe Payment Gateway](https://en-nz.wordpress.org/plugins/woocommerce-gateway-stripe/)
- [WooCommerce — increasing the WordPress memory limit](https://woocommerce.com/document/increasing-the-wordpress-memory-limit/)
- [Reactive Resume — self-hosting with Docker](https://docs.rxresu.me/self-hosting/docker)
- [Reactive Resume self-hosting setup](https://deepwiki.com/AmruthPillai/Reactive-Resume/7.3-self-hosting-setup)
- [WordPress LMS plugin comparison](https://barn2.com/blog/wordpress-lms-plugins/)

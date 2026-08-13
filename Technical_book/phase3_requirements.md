# Phase 3 — Landing Content: Technical Requirements

**Status:** Draft for review. Nothing built yet.
**Date:** 2026-08-14
**Goal:** R1 from the platform plan — about me, teaching experience, technical expertise, and navigation tabs linking to everything else.

---

## 1. Measured current state

Queried directly from the cluster, not assumed:

| Item | Value |
|---|---|
| WordPress version | **7.0.4** |
| Active theme | `twentytwentyfive` (block theme, full-site editing) |
| Active plugins | **only** `ai-provider-for-anthropic` |
| Installed but inactive | `woocommerce`, `akismet`, `hello.php` |
| Content | 1 published page, 1 draft page, 1 published post — effectively blank |
| Uploads | 12K — nothing to migrate |
| `blogname` | `blog.lennardjohn` — stale, still the old blog identity |
| `siteurl` / `home` in DB | `http://blog.lennardjohn.org` — **stale, and http** |
| WP-CLI in container | **not installed** |

Two things worth pulling out:

**WooCommerce is already installed but not activated.** Nothing to install when Phase 6 payments arrive — only to activate. It is inert as long as it stays inactive.

**The database still says `http://blog.lennardjohn.org`.** The site works because `WP_HOME`/`WP_SITEURL` constants override those values at runtime. This is the Phase 1 design behaving exactly as intended — the domain move never touched the database, which is what made it revertible. The trade-off is a latent landmine: remove the constants and the site immediately reverts to the old HTTP URL. See §6.

---

## 2. Do we need WP-CLI?

**Not strictly.** Everything in Phase 3 can be done by clicking through `/wp-admin`. The question is whether the result is reproducible.

**The container does not have it.** `wordpress:php8.2-apache` ships no `wp` binary. The official `wordpress:cli` image exists for exactly this — it contains WP-CLI but not WordPress, and is designed to be pointed at an existing install's files and database.

### Requirements to run it here

| Requirement | Detail |
|---|---|
| Image | `wordpress:cli` (official) |
| Files | Mount `wordpress-pvc` at `/var/www/html` — **read/write**, unlike the backup job |
| Node | No `nodeSelector` needed; the local-path PV's affinity pins the pod to the right node automatically |
| Concurrency | RWO permits a second pod on the same node, so it can run alongside the live WordPress pod |
| Database | `WORDPRESS_DB_*` env from `wordpress-secrets` |
| **NetworkPolicy** | **Must add a `podSelector` for the CLI pod's label.** MariaDB ingress is default-deny; without this the connection is *silently dropped* and `wp` hangs rather than erroring — exactly the trap hit in Incident #25 |
| User | The image runs as uid 33 (`www-data`), matching file ownership on the PVC |

Because I have SSH → `kubectl`, I can drive this directly. **No MCP is required to run WP-CLI.**

---

## 3. Novamira MCP — assessment

### What it is (verified)

An open-source (AGPL) WordPress plugin that turns the site into an MCP server. Free core; Pro from €49/year adds project memory and builder-specific expertise. Requires WordPress 6.9+ — **you are on 7.0.4, so it is compatible.**

Its own description of the capability it grants: *"full access to WordPress through PHP execution and filesystem operations"* — execute PHP with WordPress loaded, query and modify the database, read and edit files, run WP-CLI, build Gutenberg pages, upload plugins and themes.

### The honest concern

That capability is, precisely stated, **arbitrary remote code execution on the site, reachable over the network.** That is not a criticism of the software — it is what the tool is *for*, and it is transparent about it. The concern is the context it would be installed into:

1. **This site is destined to hold children's registration data and payment records.** The platform plan puts minors' names, and potentially medical and emergency-contact details, in this database.
2. **The site is internet-reachable** through the Cloudflare tunnel. A new arbitrary-PHP-execution endpoint on that surface is a meaningful increase in attack surface, gated only by whatever auth the plugin implements.
3. **It duplicates access I already have** through a narrower, better-controlled channel — SSH to the master node using your key, which you can revoke, and which is not exposed to the internet at all.

### Recommendation

**Don't install it for Phase 3.** Not because it is bad software, but because it buys no capability that SSH + `wordpress:cli` does not already provide, while adding an internet-facing RCE surface to a site that will later hold minors' data.

If you want it anyway — and there are reasonable reasons to, it is genuinely more ergonomic for visual page building — the mitigations that matter:

- Do **not** expose it through the Cloudflare tunnel; keep it LAN/Tailscale-only
- Activate it during build phases, deactivate when not actively using it
- Do not run it on the site once real student or payment data exists
- Treat its credential with the same care as the cluster kubeconfig

This is your call to make. I have flagged the risk; the decision is a legitimate trade-off between ergonomics and attack surface, and reasonable people choose either way.

---

## 4. What belongs in Git

This is the real architectural question for Phase 3, and it follows directly from Phase 0.

**Content cannot be GitOps'd.** Pages, posts, menus and media live in the database and the PVC. That is why backups were built first, and no tooling choice changes it.

**Configuration can be.** Which plugins are installed and active, the site title and tagline, permalink structure, and the existence of baseline pages are all reproducible as an idempotent WP-CLI script committed to the repo.

### Recommendation

`scripts/wp-bootstrap.sh` — idempotent, safe to re-run:

```sh
wp plugin is-active woocommerce || wp plugin activate woocommerce   # (Phase 6, not now)
wp option update blogname "Lennard V. John"
wp post list --post_type=page --name=about || wp post create --post_type=page --post_title="About"
```

This does **not** replace backups. It makes the *skeleton* rebuildable while the *content* stays a restore-from-backup concern. Stating that boundary explicitly is more useful than pretending either tool covers both.

---

## 5. Phase 3 work items

| # | Item | Notes |
|---|---|---|
| 1 | Site identity | `blogname` → `Lennard V. John`; set tagline |
| 2 | Landing page | Hero: who you are, teaching + technical positioning |
| 3 | About page | Background, teaching experience, technical expertise |
| 4 | Projects page | This homelab is the flagship entry |
| 5 | Now page | "Currently working on" |
| 6 | Navigation | Tabs across the top; placeholders for Learn / Camp / Resume |
| 7 | Placeholder pages | Stubs so navigation is not broken before Phases 4–9 land |

**Content source already exists.** The retired static landing page (`kubernetes/landing/configmap.yaml`) contains a written bio, a technology stack list, and social links — all still in Git and directly reusable as copy for items 2–4.

**Theme:** stay on `twentytwentyfive`. It is a block theme with full-site editing, so headers, navigation and page layouts are editable without writing a child theme. Introducing a custom theme adds a maintenance burden Phase 3 does not need.

---

## 6. Decisions needed

1. **Tooling** — WP-CLI via `wordpress:cli` pod (reproducible, I can drive it), the wp-admin UI (visual, manual), or Novamira MCP (visual + agent-driven, with the surface discussed in §3)?
2. **The stale `siteurl`/`home` in the database.** Options: (a) leave it — the constants work and the setup stays revertible; (b) update the DB to `https://lennardjohn.org` so the two agree and the landmine is removed, now that verified backups exist. Not required for Phase 3 either way.
3. **`ai-provider-for-anthropic`** is the only active plugin. Is it in use, or leftover experimentation? If unused it should be deactivated — every active plugin is attack surface and load on a site that will take payments.
4. **Tone of the landing page** — portfolio aimed at employers, or a business front door for the camp and LMS? These pull the copy in different directions, and it is worth deciding before writing rather than after.

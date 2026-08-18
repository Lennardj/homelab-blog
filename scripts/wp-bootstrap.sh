#!/usr/bin/env sh
# Idempotent WordPress site skeleton bootstrap.
#
# Creates or updates the baseline pages from wordpress-content/, sets the site
# identity, configures the static front page, and rebuilds the navigation menu.
# Safe to re-run: existing pages are updated in place by slug, never duplicated.
#
# WHAT THIS DOES AND DOES NOT COVER
# This makes the site SKELETON reproducible from Git - which pages exist, what
# they contain, the menu, the site title. It does NOT make WordPress as a whole
# reproducible: posts written later, uploaded media, plugin settings and user
# accounts all live in the database and the PVC, and are a restore-from-backup
# concern. Stating that boundary is more useful than pretending either tool
# covers both. See KNOWLEDGE_BASE.md section 16.
#
# HOW TO RUN
# This runs INSIDE the wpcli pod, which has the content files copied to
# /tmp/content. From the master node:
#
#   POD=$(kubectl get pod -n wordpress -l app=wpcli -o jsonpath='{.items[0].metadata.name}')
#   kubectl exec -n wordpress $POD -- rm -rf /tmp/content     # <- REQUIRED
#   kubectl cp /tmp/content wordpress/$POD:/tmp/content
#   kubectl exec -n wordpress deploy/wpcli -- sh /tmp/content/wp-bootstrap.sh
#
# The `rm -rf` is NOT optional. `kubectl cp <dir> pod:/path` NESTS the copy when
# /path already exists, producing /tmp/content/content/ while the stale files
# stay at /tmp/content/. This script then reads the OLD files and reports
# "updated" for every page while silently reapplying previous content - a
# failure that looks exactly like success. Deleting the target first is the fix.
set -eu

CONTENT_DIR="${CONTENT_DIR:-/tmp/content}"

# --- site identity -----------------------------------------------------------
echo "== site identity =="
wp option update blogname "Lennard V. John"
wp option update blogdescription "Platform Engineer"

# --- theme -------------------------------------------------------------------
# The child theme is mounted into wp-content/themes/lennardjohn from a ConfigMap
# (kubernetes/wordpress/theme-configmap.yaml), so it appears without ever being
# uploaded. Activation is the only step that touches the database.
echo "== theme =="
if wp theme is-installed lennardjohn 2>/dev/null; then
  if [ "$(wp theme get lennardjohn --field=status)" != "active" ]; then
    wp theme activate lennardjohn
  else
    echo "  lennardjohn already active"
  fi
else
  echo "  !! lennardjohn theme not found - is the ConfigMap mounted?" >&2
fi

# --- plugins -----------------------------------------------------------------
# Declared here rather than installed by clicking, so the plugin set is
# reproducible from Git. These install onto the PVC, which the nightly backup
# already covers.
#
# Kadence Blocks supplies carousels, sliders, tabs and accordions AS BLOCKS -
# so pages stay readable block markup rather than becoming opaque builder JSON.
# That is the same property that ruled out Elementor.
echo "== plugins =="
for plugin in kadence-blocks woocommerce; do
  if wp plugin is-installed "$plugin" 2>/dev/null; then
    if [ "$(wp plugin get "$plugin" --field=status)" != "active" ]; then
      wp plugin activate "$plugin"
    else
      echo "  $plugin already active"
    fi
  else
    wp plugin install "$plugin" --activate
  fi
done

# Deactivate anything not declared above and not deliberately kept.
# ai-provider-for-anthropic is left alone - it is an official WordPress AI Team
# provider shim, inert without an API key, and its removal is the owner's call.

# --- woocommerce settings ----------------------------------------------------
# Tech camp places are sold as WooCommerce products with stock management, where
# STOCK IS THE CAPACITY CAP. That is not a workaround - it is exactly what stock
# management does, and it means WooCommerce handles the race condition when two
# parents try to buy the last place at the same moment. No events plugin and no
# licence needed.
#
# Every value here is set explicitly rather than left to the setup wizard, so a
# rebuilt site behaves identically instead of depending on someone clicking
# through onboarding the same way twice.
if wp plugin is-active woocommerce 2>/dev/null; then
  echo "== woocommerce settings =="

  wp option update woocommerce_store_country "NZ:*" >/dev/null
  wp option update woocommerce_currency "NZD" >/dev/null
  wp option update woocommerce_currency_pos "left" >/dev/null
  wp option update woocommerce_price_thousand_sep "," >/dev/null
  wp option update woocommerce_price_decimal_sep "." >/dev/null
  wp option update woocommerce_price_num_decimals "2" >/dev/null

  # Parents are booking a place, not opening an account. Forcing registration at
  # checkout is the single biggest cause of abandoned bookings.
  wp option update woocommerce_enable_guest_checkout "yes" >/dev/null
  wp option update woocommerce_enable_checkout_login_reminder "no" >/dev/null
  wp option update woocommerce_enable_signup_and_login_from_checkout "no" >/dev/null

  # Stock is the capacity mechanism, so it must be on globally.
  wp option update woocommerce_manage_stock "yes" >/dev/null
  # Unpaid orders release their place after 60 minutes. Without this a abandoned
  # checkout holds a seat indefinitely and the class shows full when it is not.
  wp option update woocommerce_hold_stock_minutes "60" >/dev/null
  wp option update woocommerce_notify_low_stock "yes" >/dev/null
  wp option update woocommerce_notify_low_stock_amount "5" >/dev/null
  wp option update woocommerce_hide_out_of_stock_items "no" >/dev/null

  # No physical goods: nothing ships, nothing weighs anything.
  wp option update woocommerce_ship_to_countries "disabled" >/dev/null
  wp option update woocommerce_enable_shipping_calc "no" >/dev/null
  wp option update woocommerce_calc_shipping "no" >/dev/null

  # Reviews on a children's camp booking are not wanted.
  wp option update woocommerce_enable_reviews "no" >/dev/null

  # Taxes left OFF deliberately. Whether GST applies depends on registration
  # status - that is the owner's decision, not a default to guess at.
  wp option update woocommerce_calc_taxes "no" >/dev/null

  # Send parents straight to the cart after adding a place, rather than leaving
  # them on the page wondering whether it worked.
  wp option update woocommerce_cart_redirect_after_add "yes" >/dev/null

  echo "  configured (NZD, guest checkout, stock management, no shipping/tax)"
fi

# --- pages -------------------------------------------------------------------
# Upsert by slug. `wp post create` would happily create a fifth page called
# "About"; looking the slug up first is what makes this re-runnable.
# Fourth argument is an optional PARENT SLUG. Parents must be created before
# their children, hence the ordering below. Setting post_parent is what produces
# the nested URLs (/about/now/ rather than /now/).
upsert_page() {
  slug="$1"
  title="$2"
  file="$CONTENT_DIR/$3"
  parent_slug="${4:-}"

  if [ ! -f "$file" ]; then
    echo "  !! missing content file: $file" >&2
    return 1
  fi

  parent_id=0
  if [ -n "$parent_slug" ]; then
    parent_id=$(wp post list --post_type=page --name="$parent_slug" --post_status=any --field=ID | head -n1)
    if [ -z "$parent_id" ]; then
      echo "  !! parent '$parent_slug' not found for '$slug'" >&2
      return 1
    fi
  fi

  id=$(wp post list --post_type=page --name="$slug" --post_status=any --field=ID | head -n1)

  if [ -z "$id" ]; then
    id=$(wp post create "$file" \
      --post_type=page \
      --post_title="$title" \
      --post_name="$slug" \
      --post_status=publish \
      --post_parent="$parent_id" \
      --porcelain)
    echo "  created  $slug (#$id)"
  else
    wp post update "$id" "$file" \
      --post_title="$title" \
      --post_status=publish \
      --post_parent="$parent_id" >/dev/null
    echo "  updated  $slug (#$id)"
  fi
}

echo "== pages =="
upsert_page home     "Home"     home.html
upsert_page resume   "Resume"   resume.html

# About
upsert_page about    "About"    about.html
upsert_page about-me "About Me" about-me.html about
upsert_page now      "Now"      now.html      about

# Projects
upsert_page projects "Projects" projects.html
upsert_page homelab-platform            "Homelab Platform"              homelab-platform.html            projects
upsert_page azure-school-infrastructure "Azure School Infrastructure"   azure-school-infrastructure.html projects
upsert_page kubernetes                  "Kubernetes Platform"           kubernetes.html                  projects
upsert_page infrastructure-automation   "Infrastructure Automation"     infrastructure-automation.html   projects
upsert_page education-digital-technology "Education & Digital Technology" education-digital-technology.html projects

# Writing
upsert_page writing   "Writing"   writing.html
upsert_page blog      "Blog"      blog.html      writing
upsert_page guides    "Guides"    guides.html    writing
upsert_page lab-notes "Lab Notes" lab-notes.html writing

# Education
upsert_page education "Education" education.html
upsert_page teaching  "Teaching"  teaching.html  education
upsert_page tech-camp "Tech Camp" tech-camp.html education
upsert_page resources "Resources" resources.html education

# Retired pages. Their content moved into the new structure; functions.php
# 301-redirects the old URLs so existing links do not break.
echo "== retired pages =="
for old in learn camp; do
  oid=$(wp post list --post_type=page --name="$old" --post_status=any --field=ID | head -n1)
  if [ -n "$oid" ]; then
    wp post delete "$oid" --force >/dev/null
    echo "  deleted  $old (#$oid)"
  fi
done

# --- posts -------------------------------------------------------------------
# Articles republished from dev.to. Upserted by slug like pages, so re-running
# updates rather than duplicating.
#
# post_date is set to the ORIGINAL publication date so the archive reads in true
# chronological order rather than showing everything as published today.
#
# _canonical_url points at the dev.to original. Without it, the same text lives
# at two URLs with no signal about which is authoritative, and search engines
# default to the higher-authority domain. See functions.php.
upsert_post() {
  slug="$1"
  title="$2"
  file="$CONTENT_DIR/posts/$3"
  date="$4"
  canonical="$5"
  tags="$6"
  excerpt="$7"

  if [ ! -f "$file" ]; then
    echo "  !! missing content file: $file" >&2
    return 1
  fi

  id=$(wp post list --post_type=post --name="$slug" --post_status=any --field=ID | head -n1)

  if [ -z "$id" ]; then
    id=$(wp post create "$file" \
      --post_type=post \
      --post_title="$title" \
      --post_name="$slug" \
      --post_status=publish \
      --post_date="$date" \
      --tags_input="$tags" \
      --post_excerpt="$excerpt" \
      --porcelain)
    echo "  created  $slug (#$id)"
  else
    wp post update "$id" "$file" \
      --post_title="$title" \
      --post_status=publish \
      --post_date="$date" \
      --tags_input="$tags" \
      --post_excerpt="$excerpt" >/dev/null
    echo "  updated  $slug (#$id)"
  fi

  wp post meta update "$id" _canonical_url "$canonical" >/dev/null
}

echo "== posts =="
upsert_post fixing-proxmox-terraform-deletes \
  "Fixing Proxmox Terraform Deletes with curl + jq" \
  fixing-proxmox-terraform-deletes.html \
  "2026-04-07 20:53:52" \
  "https://dev.to/lennardj/fixing-proxmox-terraform-deletes-with-curl-jq-4p54" \
  "devops,terraform,automation" \
  "The Proxmox Terraform provider cannot delete a running VM, so every destroy failed the pipeline. A small curl and jq workaround that stops the VM first."

upsert_post built-a-production-platform \
  "I Built a Production Platform… Just to Write a Blog" \
  built-a-production-platform.html \
  "2026-03-31 09:24:21" \
  "https://dev.to/lennardj/i-built-a-production-platform-just-to-write-a-blog-5b91" \
  "devops,kubernetes,terraform,ansible" \
  "I wanted a place to write. I ended up with a 3-node Kubernetes cluster on bare metal, automated end to end with Terraform and Ansible, plus GitOps, monitoring and a zero-trust tunnel. Why, and everything that broke."

upsert_post lpic-1-101-1-cheat-sheet \
  "LPIC-1 Lesson 101.1 Cheat Sheet" \
  lpic-1-101-1-cheat-sheet.html \
  "2025-01-16 08:06:31" \
  "https://dev.to/lennardj/lpic-1-lesson-1011-cheat-sheet-4p5" \
  "lpic1,linux" \
  "Hardware discovery, kernel modules, pseudo-filesystems and package managers — a condensed reference for LPIC-1 objective 101.1."

# --- front page and posts page -----------------------------------------------
# Without show_on_front=page, WordPress shows the post roll at / instead of the
# landing page. page_for_posts then gives the posts their own URL at /blog/.
# The Blog page's own content is ignored by WordPress - the theme's home.html
# template renders the post list instead.
echo "== front page =="
HOME_ID=$(wp post list --post_type=page --name=home --field=ID | head -n1)
BLOG_ID=$(wp post list --post_type=page --name=blog --field=ID | head -n1)
wp option update show_on_front page
wp option update page_on_front "$HOME_ID"
wp option update page_for_posts "$BLOG_ID"
echo "  front page -> #$HOME_ID, posts page -> #$BLOG_ID"

# --- permalinks --------------------------------------------------------------
# Pretty permalinks, so pages resolve at /about/ rather than /?page_id=7.
echo "== permalinks =="
wp option update permalink_structure "/%year%/%monthnum%/%day%/%postname%/"
wp rewrite flush --hard

# --- navigation --------------------------------------------------------------
# Block themes store the menu as a wp_navigation post containing block markup,
# not as a classic nav menu. Rebuilt from scratch each run so the menu always
# matches this script rather than drifting.
echo "== navigation =="
# Submenus use wp:navigation-submenu, which is itself a link - so the parent
# item stays clickable and each section landing page is reachable, rather than
# being a dead label that only opens a dropdown.
NAV_FILE=$(mktemp)
{
  printf '<!-- wp:navigation-link {"label":"Home","url":"/","kind":"custom","isTopLevelLink":true} /-->\n'

  printf '<!-- wp:navigation-submenu {"label":"About","url":"/about/","kind":"custom","isTopLevelItem":true} -->\n'
  printf '  <!-- wp:navigation-link {"label":"About Me","url":"/about/about-me/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Now","url":"/about/now/","kind":"custom"} /-->\n'
  printf '<!-- /wp:navigation-submenu -->\n'

  printf '<!-- wp:navigation-submenu {"label":"Projects","url":"/projects/","kind":"custom","isTopLevelItem":true} -->\n'
  printf '  <!-- wp:navigation-link {"label":"Homelab Platform","url":"/projects/homelab-platform/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Azure School Infrastructure","url":"/projects/azure-school-infrastructure/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Kubernetes Platform","url":"/projects/kubernetes/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Infrastructure Automation","url":"/projects/infrastructure-automation/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Education &amp; Digital Technology","url":"/projects/education-digital-technology/","kind":"custom"} /-->\n'
  printf '<!-- /wp:navigation-submenu -->\n'

  printf '<!-- wp:navigation-submenu {"label":"Writing","url":"/writing/","kind":"custom","isTopLevelItem":true} -->\n'
  printf '  <!-- wp:navigation-link {"label":"Blog","url":"/writing/blog/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Guides","url":"/writing/guides/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Lab Notes","url":"/writing/lab-notes/","kind":"custom"} /-->\n'
  printf '<!-- /wp:navigation-submenu -->\n'

  printf '<!-- wp:navigation-submenu {"label":"Education","url":"/education/","kind":"custom","isTopLevelItem":true} -->\n'
  printf '  <!-- wp:navigation-link {"label":"Teaching","url":"/education/teaching/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Tech Camp","url":"/education/tech-camp/","kind":"custom"} /-->\n'
  printf '  <!-- wp:navigation-link {"label":"Resources","url":"/education/resources/","kind":"custom"} /-->\n'
  printf '<!-- /wp:navigation-submenu -->\n'

  printf '<!-- wp:navigation-link {"label":"Resume","url":"/resume/","kind":"custom","isTopLevelLink":true} /-->\n'
} > "$NAV_FILE"

NAV_ID=$(wp post list --post_type=wp_navigation --post_status=any --field=ID | head -n1)
if [ -z "$NAV_ID" ]; then
  NAV_ID=$(wp post create "$NAV_FILE" \
    --post_type=wp_navigation \
    --post_title="Main Navigation" \
    --post_status=publish \
    --porcelain)
  echo "  created navigation (#$NAV_ID)"
else
  wp post update "$NAV_ID" "$NAV_FILE" --post_status=publish >/dev/null
  echo "  updated navigation (#$NAV_ID)"
fi
rm -f "$NAV_FILE"

# --- discourage stale caches -------------------------------------------------
wp cache flush

echo
echo "done. pages:"
wp post list --post_type=page --fields=ID,post_name,post_title,post_status

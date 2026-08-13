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
#   kubectl cp wordpress-content wordpress/<wpcli-pod>:/tmp/content
#   kubectl exec -n wordpress deploy/wpcli -- sh /tmp/content/wp-bootstrap.sh
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
for plugin in kadence-blocks; do
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

# --- pages -------------------------------------------------------------------
# Upsert by slug. `wp post create` would happily create a fifth page called
# "About"; looking the slug up first is what makes this re-runnable.
upsert_page() {
  slug="$1"
  title="$2"
  file="$CONTENT_DIR/$3"

  if [ ! -f "$file" ]; then
    echo "  !! missing content file: $file" >&2
    return 1
  fi

  id=$(wp post list --post_type=page --name="$slug" --post_status=any --field=ID | head -n1)

  if [ -z "$id" ]; then
    id=$(wp post create "$file" \
      --post_type=page \
      --post_title="$title" \
      --post_name="$slug" \
      --post_status=publish \
      --porcelain)
    echo "  created  $slug (#$id)"
  else
    wp post update "$id" "$file" \
      --post_title="$title" \
      --post_status=publish >/dev/null
    echo "  updated  $slug (#$id)"
  fi
}

echo "== pages =="
upsert_page home     "Home"        home.html
upsert_page about    "About"       about.html
upsert_page projects "Projects"    projects.html
upsert_page now      "Now"         now.html
upsert_page learn    "Learn"       learn.html
upsert_page camp     "Tech Camp"   camp.html
upsert_page resume   "Resume"      resume.html

# --- front page --------------------------------------------------------------
# Without this WordPress shows the blog roll at /, not the landing page.
echo "== front page =="
HOME_ID=$(wp post list --post_type=page --name=home --field=ID | head -n1)
wp option update show_on_front page
wp option update page_on_front "$HOME_ID"
echo "  front page -> #$HOME_ID"

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
NAV_FILE=$(mktemp)
{
  printf '<!-- wp:navigation-link {"label":"Home","url":"/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"About","url":"/about/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"Projects","url":"/projects/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"Learn","url":"/learn/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"Tech Camp","url":"/camp/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"Resume","url":"/resume/","kind":"custom","isTopLevelLink":true} /-->\n'
  printf '<!-- wp:navigation-link {"label":"Now","url":"/now/","kind":"custom","isTopLevelLink":true} /-->\n'
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

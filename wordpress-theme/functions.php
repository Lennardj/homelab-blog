<?php
/**
 * Lennard V. John child theme.
 *
 * Block themes do not reliably enqueue a child theme's style.css on their
 * own, so both parent and child stylesheets are enqueued explicitly here.
 * The child depends on the parent so cascade order is deterministic rather
 * than incidental.
 *
 * @package lennardjohn
 */

declare(strict_types=1);

/**
 * 301 redirects for URLs retired by the 2026-08 site restructure.
 *
 * Pages moved under section parents, so their URLs changed (/now/ became
 * /about/now/, /blog/ became /writing/blog/). WordPress does not redirect a page
 * whose parent changed - the old path simply 404s - and two of these were
 * deleted outright. Anything already linking to the old URLs, including the
 * dev.to articles pointing at this site, would break silently.
 *
 * Kept in code rather than a redirect plugin so the mapping is version
 * controlled and reviewable alongside the structure change that caused it.
 */
add_action(
    'template_redirect',
    static function (): void {
        if ( ! is_404() ) {
            return;
        }

        $map = array(
            'now'   => '/about/now/',
            'blog'  => '/writing/blog/',
            'learn' => '/education/resources/',
            'camp'  => '/education/tech-camp/',
        );

        $path = trim( (string) wp_parse_url( add_query_arg( array() ), PHP_URL_PATH ), '/' );

        if ( isset( $map[ $path ] ) ) {
            wp_safe_redirect( home_url( $map[ $path ] ), 301 );
            exit;
        }
    }
);

/**
 * Footer credit line with the current year.
 *
 * WordPress has no core block that renders the current year, and hardcoding it
 * into the template guarantees a footer that silently goes stale every January.
 * A shortcode is the smallest correct fix; parts/footer.html calls it through a
 * wp:shortcode block, because plain paragraph blocks in a template part do not
 * run shortcodes.
 */
add_shortcode(
    'lj_footer_credit',
    static function (): string {
        return sprintf(
            '<p class="has-small-font-size">&copy; %s %s</p>',
            esc_html( wp_date( 'Y' ) ),
            esc_html( get_bloginfo( 'name' ) )
        );
    }
);

/**
 * Emit a canonical link for posts republished from elsewhere.
 *
 * Three posts here were originally published on dev.to. Serving the same text at
 * two URLs with no canonical signal means search engines pick a winner
 * themselves, and they usually pick the higher-authority domain - so the copy on
 * your own site loses. Declaring the original explicitly keeps attribution
 * correct instead of leaving it to chance.
 *
 * Set per post with:
 *   wp post meta update <id> _canonical_url "https://dev.to/..."
 *
 * To make THIS site canonical instead (better long term - own your content),
 * remove the meta here and set canonical_url on the dev.to article to point back
 * at lennardjohn.org. dev.to supports that in its article settings.
 */
add_action(
    'wp_head',
    static function (): void {
        if ( ! is_singular() ) {
            return;
        }

        $canonical = get_post_meta( get_the_ID(), '_canonical_url', true );

        if ( ! is_string( $canonical ) || '' === $canonical ) {
            return;
        }

        printf(
            '<link rel="canonical" href="%s" />' . "\n",
            esc_url( $canonical )
        );
    },
    1
);

/**
 * WordPress emits its own canonical tag via rel_canonical(). Leaving both in
 * place would produce two competing canonical links on the same page, which
 * search engines treat as no canonical at all.
 */
add_action(
    'template_redirect',
    static function (): void {
        if ( is_singular() && get_post_meta( get_the_ID(), '_canonical_url', true ) ) {
            remove_action( 'wp_head', 'rel_canonical' );
        }
    }
);

add_action(
    'wp_enqueue_scripts',
    static function (): void {
        wp_enqueue_style(
            'twentytwentyfive-parent',
            get_template_directory_uri() . '/style.css',
            array(),
            wp_get_theme( get_template() )->get( 'Version' )
        );

        /*
         * Version from the file's mtime, NOT the theme header.
         *
         * The stylesheet is served through Cloudflare with max-age=14400, so a
         * static ?ver=1.0.0 means the cache key never changes and visitors keep
         * the old CSS for up to four hours after a deploy - while the file on
         * disk is already correct, which makes a successful deploy look like a
         * silent failure.
         *
         * The theme is re-cloned from Git into a fresh emptyDir on every pod
         * start, so mtime changes on every deploy and the cache busts by itself.
         * No version bump to remember.
         */
        $style_path = get_stylesheet_directory() . '/style.css';
        $style_ver  = file_exists( $style_path )
            ? (string) filemtime( $style_path )
            : (string) wp_get_theme()->get( 'Version' );

        wp_enqueue_style(
            'lennardjohn-child',
            get_stylesheet_directory_uri() . '/style.css',
            array( 'twentytwentyfive-parent' ),
            $style_ver
        );
    }
);

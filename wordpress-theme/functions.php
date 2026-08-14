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

        wp_enqueue_style(
            'lennardjohn-child',
            get_stylesheet_directory_uri() . '/style.css',
            array( 'twentytwentyfive-parent' ),
            wp_get_theme()->get( 'Version' )
        );
    }
);

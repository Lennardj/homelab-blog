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

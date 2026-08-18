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
 * Tech camp SKUs, grouped by session.
 *
 * The "-2" entries are overflow classes that run alongside the first when it
 * fills. They are draft until needed.
 */
function lj_camp_skus(): array {
    return array(
        'morning'   => array( 'camp-morning', 'camp-morning-2' ),
        'afternoon' => array( 'camp-afternoon', 'camp-afternoon-2' ),
    );
}

/**
 * Full-day price. A single session is £/$140; both together are 200 rather than
 * 280, so the discount is derived rather than hardcoded - change the session
 * price and the maths still holds.
 */
function lj_camp_full_day_price(): float {
    return (float) apply_filters( 'lj_camp_full_day_price', 200 );
}

/**
 * Apply the full-day discount when a cart contains both a morning and an
 * afternoon session.
 *
 * WHY A DISCOUNT AND NOT A "FULL DAY" PRODUCT
 * A separate full-day SKU would carry its own stock, and nothing would stop
 * 28 morning + 28 full-day bookings putting 56 children in a room built for 28.
 * WooCommerce cannot share stock between products, and Product Bundles is a paid
 * extension. Selling the two real sessions keeps every capacity count honest,
 * and the discount is the only thing that needs adding.
 */
add_action(
    'woocommerce_cart_calculate_fees',
    static function ( $cart ): void {
        if ( is_admin() && ! defined( 'DOING_AJAX' ) ) {
            return;
        }

        if ( ! $cart instanceof WC_Cart ) {
            return;
        }

        $skus         = lj_camp_skus();
        $morning_cost = null;
        $after_cost   = null;

        foreach ( $cart->get_cart() as $item ) {
            if ( empty( $item['data'] ) || ! $item['data'] instanceof WC_Product ) {
                continue;
            }

            $sku   = (string) $item['data']->get_sku();
            $price = (float) $item['data']->get_price();

            if ( in_array( $sku, $skus['morning'], true ) && null === $morning_cost ) {
                $morning_cost = $price;
            }

            if ( in_array( $sku, $skus['afternoon'], true ) && null === $after_cost ) {
                $after_cost = $price;
            }
        }

        if ( null === $morning_cost || null === $after_cost ) {
            return;
        }

        $discount = ( $morning_cost + $after_cost ) - lj_camp_full_day_price();

        if ( $discount > 0 ) {
            $cart->add_fee( 'Full-day discount', -$discount );
        }
    }
);

/**
 * "Book the full day" link handler - adds both sessions in one click.
 *
 * WooCommerce's ?add-to-cart= only accepts a single product, so booking both
 * sessions would otherwise mean two separate add-to-cart round trips and a
 * parent hoping the discount appears.
 */
add_action(
    'template_redirect',
    static function (): void {
        if ( empty( $_GET['lj_full_day'] ) || ! function_exists( 'WC' ) || ! WC()->cart ) {
            return;
        }

        $group = sanitize_key( wp_unslash( $_GET['lj_full_day'] ) );
        $skus  = lj_camp_skus();

        // "primary" books the first class of each session; "second" the overflow.
        $index = ( 'second' === $group ) ? 1 : 0;

        foreach ( array( $skus['morning'][ $index ], $skus['afternoon'][ $index ] ) as $sku ) {
            $product_id = wc_get_product_id_by_sku( $sku );
            if ( ! $product_id ) {
                continue;
            }

            $product = wc_get_product( $product_id );
            if ( $product instanceof WC_Product && $product->is_purchasable() && $product->is_in_stock() ) {
                WC()->cart->add_to_cart( $product_id, 1 );
            }
        }

        wp_safe_redirect( wc_get_cart_url() );
        exit;
    }
);

/**
 * [lj_camp_classes] - tech camp classes with a live capacity indicator.
 *
 * WooCommerce stock IS the capacity cap: manage_stock + backorders=no means a
 * class cannot be oversold, and WooCommerce resolves the race when two parents
 * buy the last place at the same moment. This shortcode only renders that state
 * - it never decides it.
 *
 * WooCommerce tracks REMAINING stock, not the original size, so each product
 * carries a _lj_capacity meta written once at creation. taken = capacity - stock.
 *
 * When a class is full the booking button is REPLACED by an email link rather
 * than disabled, so a parent has somewhere to go instead of a dead end.
 *
 * Usage: [lj_camp_classes]  or  [lj_camp_classes skus="camp-a-morning,camp-b-afternoon"]
 */
add_shortcode(
    'lj_camp_classes',
    static function ( $atts ): string {
        if ( ! function_exists( 'wc_get_product' ) ) {
            return '';
        }

        $atts = shortcode_atts(
            array(
                // Overflow classes are listed here too. They are draft until a
                // second group is needed, and draft products are skipped below,
                // so publishing one is all it takes to open it for booking.
                'skus'  => 'camp-morning,camp-afternoon,camp-morning-2,camp-afternoon-2',
                'email' => get_option( 'admin_email' ),
            ),
            $atts,
            'lj_camp_classes'
        );

        $skus = array_filter( array_map( 'trim', explode( ',', (string) $atts['skus'] ) ) );
        if ( empty( $skus ) ) {
            return '';
        }

        $rows = array();

        foreach ( $skus as $sku ) {
            $product_id = wc_get_product_id_by_sku( $sku );
            if ( ! $product_id ) {
                continue;
            }

            $product = wc_get_product( $product_id );
            if ( ! $product instanceof WC_Product ) {
                continue;
            }

            // Draft products are visible to logged-in editors only, so the page
            // is previewable before the schedule is public.
            if ( 'publish' !== $product->get_status() && ! current_user_can( 'edit_posts' ) ) {
                continue;
            }

            $capacity  = (int) get_post_meta( $product_id, '_lj_capacity', true );
            $remaining = (int) $product->get_stock_quantity();

            if ( $capacity <= 0 ) {
                $capacity = max( $remaining, 1 );
            }

            $remaining = max( 0, min( $remaining, $capacity ) );
            $taken     = $capacity - $remaining;
            $percent   = (int) round( ( $taken / $capacity ) * 100 );

            $is_full       = ( 0 === $remaining ) || ! $product->is_in_stock();
            $is_bookable   = $product->is_purchasable() && ! $is_full;
            $is_unschedule = ! $product->is_purchasable();

            if ( $is_full ) {
                $state = 'is-full';
            } elseif ( $percent >= 75 ) {
                $state = 'is-filling';
            } else {
                $state = 'is-open';
            }

            $subject = rawurlencode( 'Tech Camp waitlist - ' . $product->get_name() );
            $mailto  = 'mailto:' . antispambot( (string) $atts['email'] ) . '?subject=' . $subject;

            ob_start();
            ?>
            <div class="lj-class <?php echo esc_attr( $state ); ?>">
                <div class="lj-class__head">
                    <h3 class="lj-class__name"><?php echo esc_html( $product->get_name() ); ?></h3>
                    <?php if ( $product->get_short_description() ) : ?>
                        <p class="lj-class__when"><?php echo esc_html( wp_strip_all_tags( $product->get_short_description() ) ); ?></p>
                    <?php endif; ?>
                </div>

                <div class="lj-class__capacity">
                    <div class="lj-capacity" role="img"
                         aria-label="<?php echo esc_attr( sprintf( '%d of %d places taken', $taken, $capacity ) ); ?>">
                        <span class="lj-capacity__fill" style="width:<?php echo esc_attr( (string) $percent ); ?>%"></span>
                    </div>
                    <p class="lj-capacity__label">
                        <?php if ( $is_full ) : ?>
                            <strong>Class full</strong> &middot; <?php echo esc_html( (string) $capacity ); ?> places taken
                        <?php else : ?>
                            <strong><?php echo esc_html( (string) $remaining ); ?></strong>
                            of <?php echo esc_html( (string) $capacity ); ?> places left
                        <?php endif; ?>
                    </p>
                </div>

                <div class="lj-class__action">
                    <?php if ( $is_unschedule ) : ?>
                        <span class="lj-badge lj-badge--progress">Dates to be confirmed</span>
                    <?php elseif ( $is_bookable ) : ?>
                        <a class="wp-block-button__link wp-element-button"
                           href="<?php echo esc_url( $product->add_to_cart_url() ); ?>">
                            Book a place &middot; <?php echo wp_kses_post( $product->get_price_html() ); ?>
                        </a>
                    <?php else : ?>
                        <a class="wp-block-button__link wp-element-button lj-class__waitlist"
                           href="<?php echo esc_url( $mailto ); ?>">
                            Email me about a place
                        </a>
                    <?php endif; ?>
                </div>
            </div>
            <?php
            $rows[] = (string) ob_get_clean();
        }

        if ( empty( $rows ) ) {
            return '<p class="lj-class__empty">Class dates are being confirmed. Please check back shortly.</p>';
        }

        $output = '<div class="lj-classes">' . implode( '', $rows ) . '</div>';

        // Full-day offer, shown only when both halves of a day are actually
        // bookable. Advertising a saving a parent cannot take is worse than not
        // mentioning it.
        $skus = lj_camp_skus();

        foreach ( array( 0 => 'primary', 1 => 'second' ) as $index => $group ) {
            $morning   = wc_get_product( wc_get_product_id_by_sku( $skus['morning'][ $index ] ) );
            $afternoon = wc_get_product( wc_get_product_id_by_sku( $skus['afternoon'][ $index ] ) );

            if ( ! $morning instanceof WC_Product || ! $afternoon instanceof WC_Product ) {
                continue;
            }

            $both_open = $morning->is_purchasable() && $morning->is_in_stock()
                && $afternoon->is_purchasable() && $afternoon->is_in_stock();

            if ( ! $both_open ) {
                continue;
            }

            $saving = ( (float) $morning->get_price() + (float) $afternoon->get_price() ) - lj_camp_full_day_price();

            $output .= sprintf(
                '<div class="lj-fullday">
                    <div>
                        <strong>Book the full day</strong>
                        <span>Morning and afternoon together%s</span>
                    </div>
                    <a class="wp-block-button__link wp-element-button" href="%s">Full day &middot; %s</a>
                </div>',
                $saving > 0
                    ? ' &mdash; save ' . wp_kses_post( wc_price( $saving ) )
                    : '',
                esc_url( add_query_arg( 'lj_full_day', $group, get_permalink() ) ),
                wp_kses_post( wc_price( lj_camp_full_day_price() ) )
            );

            // Only ever offer one full-day bundle at a time.
            break;
        }

        return $output;
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

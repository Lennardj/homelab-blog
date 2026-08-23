<?php
/**
 * Plugin Name: LJ Secrets from Environment
 * Description: Supplies Stripe API keys and webhook secrets from environment variables backed by Kubernetes Secrets, so they never live in the database.
 * Version: 1.0.0
 * Author: Lennard V. John
 *
 * WHY THIS IS A MUST-USE PLUGIN AND NOT PART OF THE THEME
 *
 * This filter originally lived in the child theme. It worked for anything that
 * read settings during a request, but NOT for the Stripe webhook handler, which
 * reads its signing secret in its CONSTRUCTOR:
 *
 *   public function __construct() {
 *       $secret_key   = ( $this->testmode ? 'test_' : '' ) . 'webhook_secret';
 *       $this->secret = ! empty( $stripe_settings[ $secret_key ] ) ? ... : false;
 *   }
 *
 * That constructor runs while plugins are loading - BEFORE the theme's
 * functions.php is parsed - so a theme-registered filter is simply not there
 * yet. The handler cached `false` and every webhook failed with
 * "Webhook validation failed (empty_secret)", including correctly signed ones.
 *
 * Must-use plugins load before regular plugins, so the filter is registered
 * before WooCommerce Stripe initialises. Infrastructure configuration also has
 * no business depending on which theme happens to be active.
 *
 * @package lennardjohn
 */

declare(strict_types=1);

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Override Stripe credentials with values from the environment.
 *
 * The WooCommerce Stripe plugin stores keys in `woocommerce_stripe_settings`,
 * which puts a live secret key in wp_options and therefore in every nightly
 * backup in plaintext. Filtering the option on read keeps them in the
 * `stripe-secrets` Kubernetes Secret instead.
 *
 * Anything absent from the environment falls through to the stored value, so a
 * missing Secret degrades rather than breaking checkout outright.
 */
add_filter(
	'option_woocommerce_stripe_settings',
	static function ( $value ) {
		if ( ! is_array( $value ) ) {
			return $value;
		}

		$map = array(
			'test_publishable_key' => 'STRIPE_TEST_PUBLISHABLE_KEY',
			'test_secret_key'      => 'STRIPE_TEST_SECRET_KEY',
			'test_webhook_secret'  => 'STRIPE_TEST_WEBHOOK_SECRET',
			'publishable_key'      => 'STRIPE_LIVE_PUBLISHABLE_KEY',
			'secret_key'           => 'STRIPE_LIVE_SECRET_KEY',
			'webhook_secret'       => 'STRIPE_LIVE_WEBHOOK_SECRET',
		);

		foreach ( $map as $setting => $env_var ) {
			$env_value = getenv( $env_var );

			if ( is_string( $env_value ) && '' !== $env_value ) {
				$value[ $setting ] = $env_value;
			}
		}

		return $value;
	},
	1
);

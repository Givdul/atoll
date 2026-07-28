# Skerry licensing

Checked 2026-07-27.

## Decision

Skerry uses one concrete direct-sale mechanism: a $7.99 one-time Lemon Squeezy
product with perpetual license keys enabled. Lemon Squeezy hosts checkout and
Skerry calls its HTTPS License API directly to activate and periodically
validate the license instance.

This matches Lemon Squeezy's documented flow:

- [shareable product checkout URLs](https://docs.lemonsqueezy.com/help/products/sharing-products)
- [license activation and product-ID checks](https://docs.lemonsqueezy.com/guides/tutorials/license-keys)
- [license validation](https://docs.lemonsqueezy.com/api/license-api/validate-license-key)

There is no provider abstraction, Skerry account, subscription, custom payment
backend, telemetry, or usage metering.

## Store configuration

Create one Lemon Squeezy product configured as:

- one-time price: **$7.99 USD**
- license keys: enabled
- license expiration: none
- activation limit: the number of Macs covered by one purchase

Release builds receive the shareable `/checkout/buy/` URL and the exact IDs used
to reject licenses for another product:

```sh
SIGN_IDENTITY="Developer ID Application: ..." \
SKERRY_PURCHASE_URL="https://STORE.lemonsqueezy.com/checkout/buy/VARIANT" \
LEMON_SQUEEZY_STORE_ID="..." \
LEMON_SQUEEZY_PRODUCT_ID="..." \
LEMON_SQUEEZY_VARIANT_ID="..." \
./Scripts/build-release.sh
```

All four values are required together. The build rejects non-HTTPS or
non-Lemon-Squeezy checkout destinations. Ad-hoc builds reject any of these
values before compilation because they cannot persist license material safely.
Without them, the purchase and
activation menu items are visibly unavailable; the repository intentionally
does not contain invented production IDs or a fake checkout.

Before distribution, verify the live checkout itself displays a single $7.99
charge and that a real receipt key activates, validates, survives an app update,
and becomes invalid after disabling that key in Lemon Squeezy.

## Local behavior and privacy

The release script writes the entitlement-storage mode into the signed
`Info.plist`. Ad-hoc local builds are trial-only: they save the immutable trial
start and maximum observed wall time in `~/.skerry/trial-entitlement-v1.json`
using a `0700` directory and `0600` file. Rebuilding or replacing `Skerry.app`
keeps that file. This mode refuses to read or save license material and never
queries Keychain.

Developer ID builds use the macOS Keychain with
`AfterFirstUnlockThisDeviceOnly` accessibility. They use the new
`com.givdul.skerry.entitlement.v2` / `device-v2` record; Skerry intentionally
does not query, delete, or migrate the orphaned development record. Local
ad-hoc trial state and production Developer ID entitlement state are therefore
separate. Proving persistence across a real stable-signing update remains part
of release issue #9.

The three-day boundary in either mode is derived from the immutable start, and
the maximum observed wall time is saved so moving the clock backward expires
rather than extends or freezes the trial. Keychain operations run off the app's
main thread and stop waiting for a result after one second. At most one
uncancellable operation remains in flight; later work fails open until it
finishes, so workers cannot accumulate or overwrite newer state.

A validated license key, Lemon Squeezy instance ID, and last validation time are
kept in the same Keychain record. Licensed use is local-first and continues
offline. Skerry retries validation at most daily; a network failure or malformed
vendor response, rate limit, or temporary HTTP failure never removes previously
validated access. Re-entering the same key validates its stored instance;
a different key is refused while an active license exists, so Skerry does not
consume another activation. If saving a newly activated instance locally fails,
Skerry deactivates that instance again. A definitive invalid, disabled, expired,
wrong-product, or wrong-instance response removes licensed access and presents
the activation guidance without interrupting agent hooks.

Only the license key, a generic `Skerry on Mac` instance name, and the stored
instance ID are sent to Lemon Squeezy. Prompts, transcripts, commands, project
content, paths, agent events, and device names never cross the licensing
boundary.

After expiry Skerry hides product output and notifications, while hook delivery
continues to acknowledge quickly. The shared local lifecycle queue retains at
most 256 events, including when Skerry is not running, so an expired installation
cannot grow it without bound.

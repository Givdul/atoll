# Topside licensing

Checked 2026-07-28.

## Decision

Topside uses one concrete direct-sale mechanism: a $7.99 one-time Polar product
with one dedicated perpetual License Keys benefit attached only to Topside.
Polar hosts checkout and Topside calls the public HTTPS validation endpoint
directly.

This follows Polar's documented flow:

- [shareable Checkout Links](https://polar.sh/docs/features/checkout/links)
- [License Keys benefits](https://polar.sh/docs/features/benefits/license-keys)
- [sandbox environment](https://polar.sh/docs/integrate/sandbox)

There is no provider abstraction, Topside account, subscription, custom payment
backend, telemetry, usage metering, device activation, or deactivation.

## Polar configuration

Create one Polar product configured as:

- one-time price: **$7.99 USD**
- one dedicated License Keys benefit attached only to this product
- license expiration: none
- activation limit: none
- usage limit: none

Release builds receive the exact Checkout Link and the public organization and
benefit UUIDs used to scope every validation:

```sh
SIGN_IDENTITY="Developer ID Application: ..." \
TOPSIDE_PURCHASE_URL="https://buy.polar.sh/polar_cl_..." \
POLAR_ORGANIZATION_ID="..." \
POLAR_BENEFIT_ID="..." \
./Scripts/build-release.sh
```

All three Polar values are required together. The release script accepts only
the exact production `https://buy.polar.sh/polar_cl_...` form or Polar's
official sandbox
`https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_.../redirect` form.
It infers `api.polar.sh` or `sandbox-api.polar.sh` from that link. Both IDs must
be UUIDs. These are public identifiers: never embed an organization access
token, customer token, or webhook secret.

Ad-hoc builds reject any Polar values before compilation because they cannot
persist license material safely. Without them, purchase and license-entry menu
items are visibly unavailable; the repository intentionally contains no
invented production IDs or fake checkout.

Before distribution, verify the live checkout displays one $7.99 charge and a
real purchase key validates, survives an app update, and becomes invalid after
revoking or disabling it in Polar.

## Validation, local behavior, and privacy

Initial key entry and daily revalidation both send JSON to
`POST /v1/customer-portal/license-keys/validate`. Polar documents this endpoint
as public-client safe, so Topside sends no `Authorization` header. The request
contains only:

- the license key
- the configured public Polar organization UUID
- the configured public Polar benefit UUID

Topside accepts only a response with the same key, organization, and benefit,
`status: "granted"`, and null expiration, activation limit, and usage limit.
A missing key, revocation, disablement, wrong identifier or key, expiration, or
limit is definitive. Network failures, HTTP 408/425/422/429/5xx responses, and
malformed vendor responses are temporary and never remove previously validated
access. Licensed use remains local-first and validation is attempted at most
daily.

The release script writes the entitlement-storage mode into the signed
`Info.plist`. Ad-hoc local builds are trial-only: they save the immutable trial
start and maximum observed wall time in `~/.topside/trial-entitlement-v1.json`
using a `0700` directory and `0600` file. Rebuilding or replacing `Topside.app`
keeps that file. This mode refuses to read or save license material and never
queries Keychain.

Developer ID builds use the macOS Keychain with
`AfterFirstUnlockThisDeviceOnly` accessibility. They use the
`com.givdul.skerry.entitlement.v2` / `device-v2` record; Topside intentionally
does not query, delete, or migrate the orphaned development record. Local
ad-hoc trial state and production Developer ID entitlement state are separate.
Proving persistence across a real stable-signing update remains part of release
issue #9.

The three-day boundary in either mode is derived from the immutable start, and
the maximum observed wall time is saved so moving the clock backward expires
rather than extends or freezes the trial. Keychain operations run off the app's
main thread and stop waiting for a result after one second. At most one
uncancellable operation remains in flight; later work fails open until it
finishes, so workers cannot accumulate or overwrite newer state.

A validated license key and last validation time are kept in the same Keychain
record. Re-entering the same key validates it; a different key is refused while
an active license exists. Prompts, transcripts, commands, project content,
paths, agent events, device identifiers, and device names never cross the
licensing boundary.

After expiry Topside hides product output and notifications, while hook delivery
continues to acknowledge quickly. The shared local lifecycle queue retains at
most 256 events, including when Topside is not running, so an expired
installation cannot grow it without bound.

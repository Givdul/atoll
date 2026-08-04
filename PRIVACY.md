# Topside Privacy Policy

Topside processes coding-agent status on your Mac. It has no analytics, crash
reporting, advertising, or telemetry.

## Local data

Agent hooks send lifecycle events to a user-only Unix socket. Topside keeps only
the agent, provider session ID, normalized status, timestamps, a project-folder
label, and—when available—the originating app identity used to return to that
app. Prompts, responses, transcripts, diffs, commands, model names, environment
values, and full working-directory paths are discarded.

Settings are stored in `~/.topside/config.json`. App-owned lifecycle state and
delivery queues are stored with owner-only permissions under `~/.topside`;
lifecycle payload content is discarded after it is normalized. Live Status
repair and removal edit shared provider configuration structurally, preserving
unrelated entries and removing only exact Topside-owned commands.

Release builds store the trial start, last observation, license key, and
validation times in the macOS Keychain under the retained compatibility service
`com.givdul.skerry.entitlement.v2`. Ad-hoc development builds store trial-only
state under `~/.topside` and cannot contain licensing configuration. During an
upgrade, Topside copies known app-owned data from `~/.skerry` and then `~/.atoll`
only when the corresponding Topside item is missing; both legacy trees remain
unchanged for rollback.

## Network access

- Topside contacts Polar over HTTPS only when you open the purchase page, enter
  a license, or a stored license is due for periodic validation. Validation
  sends the license key plus Topside's public Polar organization and benefit
  identifiers. Polar's own privacy terms govern its service.
- Production builds contact the configured HTTPS Sparkle feed to check for and
  download updates. Sparkle verifies updates with the public Ed25519 key bundled
  in Topside.

Topside does not upload agent lifecycle data. Removing Topside and its
`~/.topside` directory deletes app-owned files; license state can be removed
from Keychain Access.

Questions and privacy requests can be filed through
[Topside support](https://github.com/Givdul/atoll/issues).

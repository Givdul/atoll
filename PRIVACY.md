# Skerry Privacy Policy

Skerry processes coding-agent status on your Mac. It has no analytics, crash
reporting, advertising, or telemetry.

## Local data

Agent hooks send lifecycle events to a user-only Unix socket. Skerry keeps only
the agent, provider session ID, normalized status, timestamps, a project-folder
label, and—when available—the originating app identity used to return to that
app. Prompts, responses, transcripts, diffs, commands, model names, environment
values, and full working-directory paths are discarded.

Settings use macOS user defaults. App-owned lifecycle state and delivery queues
are stored with owner-only permissions under `~/.skerry`. Release builds store
the trial start, last observation, license key, and validation times in the
macOS Keychain. Ad-hoc development builds store trial-only state under
`~/.skerry` and cannot contain licensing configuration.

## Network access

- Skerry contacts Polar over HTTPS only when you open the purchase page, enter
  a license, or a stored license is due for periodic validation. Validation
  sends the license key plus Skerry's public Polar organization and benefit
  identifiers. Polar's own privacy terms govern its service.
- Production builds contact the configured HTTPS Sparkle feed to check for and
  download updates. Sparkle verifies updates with the public Ed25519 key bundled
  in Skerry.

Skerry does not upload agent lifecycle data. Removing Skerry and its
`~/.skerry` directory deletes app-owned files; license state can be removed
from Keychain Access.

Questions and privacy requests can be filed through
[Skerry support](https://github.com/Givdul/atoll/issues).

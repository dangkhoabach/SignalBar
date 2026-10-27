# Security policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue:

- **GitHub:** Security tab → **Report a vulnerability** on this repository, or
- **Contact form** on [dangkhoabach.vn](https://dangkhoabach.vn), asking for a private channel.

Include the app version (Settings), your macOS version and the steps to reproduce. You will get
a reply within a week. Please give a fix the chance to ship before you disclose the issue
publicly.

## Supported versions

Only the latest release gets security fixes. It reaches you through **Check for Updates…**.

## Scope

In scope:

- **Server Manager:** running anything on a remote server beyond the per-server allowlist,
  injecting into the commands it builds, accepting a changed host key without asking, or
  reading the SSH credentials it stores in the Keychain.
- **Exports:** a server export that carries a credential.
- **Email reports:** using the relay to send mail to an address that was not verified, or
  reading the verification token.
- **Webhooks and checks:** a crafted response from a monitored site or webhook that makes the
  app run code or write outside its own data.
- **Updates:** installing an update that is not signed with the release key.

Out of scope:

- A Mac that is already compromised, or someone using it while it is unlocked.
- The availability of `api.dangkhoabach.vn` itself (report abuse of it through the contact
  form).

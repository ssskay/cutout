# Security Policy

## Reporting

Report security issues through
[GitHub Security Advisories](https://github.com/ssskay/cutout/security/advisories/new)
on this repository, or open an issue at
<https://github.com/ssskay/cutout/issues> if the problem is not sensitive.

This is a personal project maintained in spare time. Expect a reply within a
couple of weeks rather than a couple of hours.

## Supported versions

The most recent release is the only supported version.

## Threat model

Cutout processes local image files and writes local image files. It has no
server, no account system, no telemetry, no auto-update, and no network access.

**The app is sandboxed and ships with no `com.apple.security.network.*`
entitlement.** macOS will not permit it to open a network connection, so image
data cannot leave the machine even if the app were compromised or maliciously
modified. `scripts/release.sh` fails the build if a network entitlement appears
in either the source entitlements file or the signed bundle.

The app's file access is limited to what you explicitly hand it: images you drop
on the window or choose in an open panel, and the output folder you pick.

Releases are signed with a Developer ID certificate, notarized by Apple, and
stapled. Each release publishes a `.sha256` alongside the DMG.

## What is out of scope

- Image content itself. Cutout does not inspect, classify, or judge what you
  process.
- The accuracy of the ID-photo geometry. It is computed from Apple's Vision
  framework and displayed for you to check; it is not a guarantee that any
  authority will accept a given photo.

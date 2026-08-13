# Unsigned IPA, third-party signing, and installation

Status: workflow contract only until a GitHub macOS runner produces the artifact and the owner reports a physical-device result.

## Artifact contents

The release workflow must provide:

- `Miravo-UNSIGNED.ipa` containing `Payload/Miravo.app` from a Release `iphoneos` device build.
- SHA-256 file.
- JSON manifest with revision, build/version, bundle ID, minimum iOS, Xcode/Swift/macOS versions, architectures, and feature flags.
- Relevant dSYMs/symbol files.

Verify checksum before uploading to any signing service. The project never requests or automates iOSGods credentials.

## Signing/installing

1. Download all artifacts from the same successful workflow run.
2. Compare `sha256sum Miravo-UNSIGNED.ipa` with the provided checksum.
3. Upload the unsigned IPA through the owner’s separate signing service.
4. Confirm the signer’s output has the intended app version and bundle identifier. A changed bundle ID produces a separate app container and will not inherit on-device pending records.
5. Install according to that service’s documented method and trust/profile requirements.

Third-party certificates can be revoked and re-signers may alter/remove entitlements. Core behavior intentionally avoids App Groups, App Intents, iCloud, APNs, Sign in with Apple, extensions, and custom Keychain groups. Signing still is a trust decision: a modified signer output can inspect data entered into it.

## Physical-device smoke checklist

- [ ] Launch on the declared minimum/primary iOS without crash.
- [ ] Verify bundle/version/build and English/Albanian switch.
- [ ] Configure valid HTTPS server and log in.
- [ ] Create/edit/delete/reopen an expense while offline; pending state survives force quit.
- [ ] Restore connectivity; exactly one server record appears and status becomes synced.
- [ ] Revoke a device session and confirm sync is blocked while local viewing remains.
- [ ] Enable/disable Face ID gate.
- [ ] Capture/attach a receipt; deny camera/photo permission and confirm graceful fallback.
- [ ] Exercise Dynamic Type, VoiceOver labels, dark/high-contrast/reduced-motion states.
- [ ] Run synthetic direct Shortcut capture while app is closed; confirm it appears on next sync.
- [ ] Export pending on-device-only data before deleting an unsynced app installation.

Synchronized server data survives reinstall: sign in and bootstrap. Unsynced local data does not automatically survive container deletion, signer bundle-ID change, or uninstall; use the local pending-data export first.

# Configure the forward-update signing baseline

This is a user-operated setup guide. The build workflow does not provision keys
or change stored secrets; it consumes configured GitHub secrets on the build runner. Do not paste private keys, base64 keystore
contents or passwords into chat or commit them to Git.

## Choose and back up the identities

Use a separate persistent key for the main app and TV so their signing identities
can be managed independently. Each must remain unchanged for future updates of its
own package. Store secure offline backups of both keystores, aliases and passwords.
Losing a key can permanently prevent normal updates of apps signed by it.

With Java keytool already installed, the user can generate keys on their own
trusted computer, outside the repository. These commands prompt locally for
passwords; they deliberately contain no password arguments:

```sh
keytool -genkeypair -storetype JKS -keystore simple-live-main.jks -alias simple-live-main -keyalg RSA -keysize 4096 -validity 10000
keytool -genkeypair -storetype JKS -keystore simple-live-tv.jks -alias simple-live-tv -keyalg RSA -keysize 4096 -validity 10000
```

The user, not the assistant, performs any credential generation and secret entry.
Do not run these commands in CI or on an ephemeral runner. An existing suitable
persistent key can be used instead; retain its actual alias and passwords.

## Configure GitHub Actions secrets privately

In this repository's Settings → Secrets and variables → Actions, the user adds:

- Main: `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`.
- TV: `TV_KEYSTORE_BASE64`, `TV_STORE_PASSWORD`, `TV_KEY_PASSWORD`, `TV_KEY_ALIAS`.

Each BASE64 value is a local base64 encoding of that app's keystore bytes. Encode
and enter it using a trusted local tool directly into GitHub's secret form. It is
still a private credential, not a safe public representation. The workflow accepts
wrapped base64 and strips whitespace. The store/key passwords and alias must match
the corresponding keystore. Do not send these values through the assistant.

## Commit only the public certificate fingerprints

Read each public certificate's SHA-256 fingerprint locally (password prompts stay
local). This does not export a private key:

```sh
keytool -list -v -keystore simple-live-main.jks -alias simple-live-main
keytool -list -v -keystore simple-live-tv.jks -alias simple-live-tv
```

Copy only the SHA256 certificate fingerprint into the matching
`certificate_sha256` field in `tool/signing-baseline.json`. Colons are accepted;
otherwise use 64 hexadecimal digits. Keep the package IDs unchanged. The empty
initial fields intentionally block APK production until setup is complete.
The public fingerprint may be reviewed/shared; the keystore and passwords may not.

Changing this build input requires `python tool/version.py bump both` before the
final setup commit. CI first validates the public baseline and then checks every
finished APK's certificate against it before upload. Replacing a secret with a
different key without updating the reviewed baseline fails the build.

## Verify the baseline and next update

After the user has completed setup, run the unified workflow. Install the chosen
baseline APK and retain its ABI. Build a later source-version bump and confirm an
actual same-ABI update retains test data. Only then claim that this forward-update
path has been tested. Historical TestSigned builds are outside the new baseline;
never uninstall or clear old user data automatically to work around their keys.

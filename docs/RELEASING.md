# SideStore releases

Source: https://crunchyboy-1be9d-updates.web.app/source.json

Phone setup page: https://crunchyboy-1be9d-updates.web.app

The download site is public and unlisted. It contains the icon, release notes, and source feed. Unsigned IPAs are hosted in the
separate public `Charger1258/crunchyboy-releases` repository; no app source code goes there. GitHub code, local profile libraries, account data, passwords,
and signing credentials are not deployed. Firebase Hosting is configured separately
from Firestore in `firebase-hosting.json`; publishing only changes the download site.

## Publish after a successful build

1. Increment the marketing version and build number in `project.yml` for app updates.
   SideStore uses the marketing version to detect updates. Do not reuse it for new bytes.
2. Run the Codemagic SideStore workflow. Check simulator tests, device build, and app
   screenshots, then download its IPA and verify the published checksum.
3. Publish the approved artifact using the existing local GitHub and Firebase CLI logins:

   ```sh
   python scripts/publish_sidestore.py /path/to/StreamAnime-unsigned.ipa --notes "What changed"
   ```

   `--prepare-only` generates the site without deploying it. `--date YYYY-MM-DD`
   can preserve the intended release date when publishing an existing build.
4. Verify the live source, advertised version, download size, and IPA checksum.

The publisher keeps three release versions, checks that existing release bytes are
immutable, rejects downgrades, and verifies the deployed feed. The public GitHub app download is checksum-verified before Firebase Hosting switches
the source feed to the new release. The source uses Classic fields without
marketplace/notarization fields. App identity remains `com.streamanime.iphone`.

Codemagic also prepares `SideStore-release.zip`. It does not contain credentials.
The last deployment step currently uses the authorized local Firebase CLI session;
unattended publishing directly from Codemagic would need a separately configured,
restricted deployment identity. Do not put personal Firebase refresh tokens in CI.

The phone adds the source once. Subsequent versions appear in SideStore and still
require SideStore to sign/install them. Automatic signature refresh does not itself
download new app versions. Keep the same Apple account and update the existing app.

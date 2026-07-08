
## Install

**Requires an Apple Silicon Mac** (M1 or later — the binary is arm64-only).

1. Download `fabulous-<version>.dmg` and `fabulous-<version>.dmg.sha256` below.
2. **Verify the download** (optional but recommended):

   ```sh
   shasum -a 256 -c fabulous-<version>.dmg.sha256
   ```

3. Open the dmg and drag **fabulous** into **Applications**.
4. The app is unsigned (no paid Apple Developer certificate yet — it's a
   free-time project), so macOS will refuse to open it until you clear
   the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

**Updating from a previous version:** each release carries a fresh
ad-hoc code signature, so macOS revokes the app's Microphone and
Accessibility permissions on update. Re-grant both in System Settings →
Privacy & Security when prompted.

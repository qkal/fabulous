
## Install

**Requires an Apple Silicon Mac** (M1 or later — the binary is arm64-only).

1. Download `fabulous-<version>.dmg` below and open it.
2. Drag **fabulous** into **Applications**.
3. The app is not notarized (no Apple Developer certificate — it's a
   free-time project), so macOS will refuse to open it until you clear
   the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

**Updating from a previous version:** each release carries a fresh
ad-hoc code signature, so macOS revokes the app's Microphone and
Accessibility permissions on update. Re-grant both in System Settings →
Privacy & Security when prompted.

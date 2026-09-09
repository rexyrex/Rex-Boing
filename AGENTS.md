# Rex Boing repository instructions

After making and validating any source-code change to Rex Boing, build the
Release app with the project's normal signing settings, replace
`/Applications/Rex Boing.app` with that successful build, and relaunch it.
`./build.sh --install` does all three. Run `Tools/check.sh` before installing;
never install a build that failed validation. Preserve the user's preferences.

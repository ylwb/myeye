/// ACP UI build mode switches.
///
/// These are runtime-mutable (not const) so the user can flip them from the
/// Settings page without rebuilding the APK.
library;

/// When true (the target state), the app is driven by an ACP agent: provider /
/// model configuration UI is hidden, and the model list comes from the
/// agent's `availableModels` instead of the local catalog.
bool acpUiMode = true;

/// Explicit ACP enable switch, toggled from Settings.
///
/// Default false. Turn it on once the PRoot sandbox (node/pi/pi-acp) is
/// available in the app; if the agent can't start, generation reports an
/// error instead of silently falling through. Set false to restore the
/// legacy provider path without rebuilding.
bool acpEnabled = false;

/// ACP UI build mode switch.
///
/// When true (the target state), the app is driven purely by an ACP agent:
/// provider / model configuration UI is hidden, and the model list comes
/// from the agent's `availableModels` instead of the local catalog.
///
/// Set to false to restore the legacy provider-driven UI during migration.
const bool acpUiMode = true;

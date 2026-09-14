#pragma once

namespace UEEditorMCPLuaAssetMenu
{
	/** Register the Blueprint Content Browser action. */
	void Install();

	/** Remove the menu action and any pending startup callback. */
	void Remove();
}

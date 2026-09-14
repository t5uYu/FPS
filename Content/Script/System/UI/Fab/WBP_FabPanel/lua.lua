-- Compatibility shim for a Blueprint GetModuleName accidentally set to
-- "System.UI.Fab.WBP_FabPanel.lua". The canonical module remains
-- "System.UI.Fab.WBP_FabPanel".
return require("System.UI.Fab.WBP_FabPanel")

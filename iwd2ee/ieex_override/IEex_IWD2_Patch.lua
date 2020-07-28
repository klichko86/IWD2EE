
dofile("override/IEex_Core_Patch.lua")
dofile("override/IEex_Creature_Patch.lua")
dofile("override/IEex_Opcode_Patch.lua")
dofile("override/IEex_Gui_Patch.lua")
dofile("override/IEex_Key_Patch.lua")

-- Actually IWD2's "operator_new" and "operator_delete", (needed for IEex memory to interact with engine)
-- NOTE: THESE NEED TO BE THE LAST LINES EXECUTED DURING INITIAL STARTUP!
IEex_DefineAssemblyLabel("_malloc", 0x7FC95B)
IEex_DefineAssemblyLabel("_free", 0x7FC984)

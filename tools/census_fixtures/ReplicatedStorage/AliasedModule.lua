-- MUST NOT FLAG: loaded at run time from a name held in a table, so it is never written as
-- require(Shared.AliasedModule). Only the bare string "AliasedModule" ever appears.
local AliasedModule = {}

AliasedModule.Setting = 3

return AliasedModule

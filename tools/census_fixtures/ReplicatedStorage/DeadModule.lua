-- MUST FLAG: nothing anywhere names this module.
local DeadModule = {}

function DeadModule.Unreachable()
	return true
end

return DeadModule

local LiveModule = {}

-- MUST FLAG: nothing references this, as a call or as a value.
function LiveModule.NeverCalled()
	return "nobody asks"
end

-- MUST NOT FLAG: assigned to a hook and invoked through it. Never written as .CalledAsValue(.
function LiveModule.CalledAsValue(part)
	return part ~= nil
end

-- MUST NOT FLAG: an ordinary call site.
function LiveModule.CalledNormally()
	return 1
end

return LiveModule

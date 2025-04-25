--!strict
local Argon = script:FindFirstAncestor("Lemonade")

local Types = require(Argon.Types)

return function(): Types.Ref
	local buf = buffer.create(16)

	for i = 0, 15 do
		buffer.writeu8(buf, i, math.random(0, 255))
	end

	return buf
end

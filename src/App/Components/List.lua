local Argon = script:FindFirstAncestor('Argon')
local App = Argon.App

local Fusion = require(Argon.Packages.Fusion)

local Theme = require(App.Theme)

local New = Fusion.New
local Hydrate = Fusion.Hydrate

type Props = {
	[any]: any,
}

return function(props: Props): UIListLayout
	return Hydrate(New 'UIListLayout' {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = Theme.ListSpacing,
	})(props)
end

local Argon = script:FindFirstAncestor("Lemonade")

local App = Argon.App
local Components = App.Components

local Fusion = require(Argon.Packages.Fusion)

local Theme = require(App.Theme)

local Padding = require(Components.Padding)
local Text = require(Components.Text)
local Box = require(Components.Box)

local Value = Fusion.Value
local OnChange = Fusion.OnChange
local Children = Fusion.Children

type Props = {
	App: { [string]: any },
	Message: string,
}

return function(): Frame
	local absoluteSize = Value(Vector2.zero)

	return Box {
		Size = UDim2.new(1, 0, 0, Theme.CompSizeY.Large * 1),

		[OnChange "AbsoluteSize"] = function(size)
			absoluteSize:set(size)
		end,

		[Children] = {
			Padding {},
			Text {
				Text = "Lemonade is running and syncing files!",
				TextWrapped = true,
				Font = Theme.Fonts.Mono,
				TextSize = Theme.TextSize.Medium,
				Color = Theme.Colors.TextDimmed,
			},
		},
	}
end

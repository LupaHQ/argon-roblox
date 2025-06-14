local Argon = script:FindFirstAncestor("Lemonade")

local App = Argon.App
local Components = App.Components
local Widgets = App.Widgets

local Fusion = require(Argon.Packages.Fusion)

local Types = require(Argon.Types)

local Assets = require(App.Assets)
local Theme = require(App.Theme)

local ProjectDetails = require(Widgets.ProjectDetails)
local TextButton = require(Components.TextButton)
local IconButton = require(Components.IconButton)
local Container = require(Components.Container)
local Padding = require(Components.Padding)
local Text = require(Components.Text)
local List = require(Components.List)
local Box = require(Components.Box)

local Value = Fusion.Value
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children
local Cleanup = Fusion.Cleanup
local peek = Fusion.peek

type Props = {
	App: { [string]: any },
	Project: Fusion.Value<Types.Project>,
}

return function(props: Props): { Instance }
	local syncedText = Value("just now")
	local projectDetailsWidget = Value(nil)

	local function updateSyncedText()
		return task.spawn(function()
			while true do
				local elapsed = os.time() - peek(props.App.lastSync)
				local interval = 1
				local text

				if elapsed < 1 then
					text = "just now"
				elseif elapsed < 60 then
					text = math.floor(elapsed) .. "s ago"
				elseif elapsed < 3600 then
					interval = 60
					text = elapsed // interval .. "m ago"
				elseif elapsed < 86400 then
					interval = 3600
					text = elapsed // interval .. "h ago"
				else
					interval = 86400
					text = elapsed // interval .. "d ago"
				end

				syncedText:set(text)
				task.wait(interval)
			end
		end)
	end

	local thread = updateSyncedText()
	local disconnect = Observer(props.App.lastSync):onChange(function()
		task.cancel(thread)
		thread = updateSyncedText()
	end)

	return {
		List {},
		Box {
			Size = UDim2.new(1, 0, 0, Theme.CompSizeY.Large * 1.5),
			[Children] = {
				Padding {},
				Text {
					Size = UDim2.fromScale(0.8, 0.6),
					Text = Computed(function(use)
						return use(props.Project).name
					end),
					Font = Theme.Fonts.Bold,
					Scaled = true,
				},
				Text {
					Position = UDim2.fromScale(0, 0.6),
					Size = UDim2.fromScale(0.8, 0.4),
					Text = `{props.App.host}:{props.App.port}`,
					TextSize = Theme.TextSize.Small,
					Font = Theme.Fonts.Mono,
					Scaled = true,
				},
				Text {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -2, 0.5, 0),
					Text = Computed(function(use)
						local lastSyncKind = use(props.App.lastSyncKind)
						local action = ""

						if lastSyncKind == "Server" then
							action = "↓"
						elseif lastSyncKind == "Client" then
							action = "↑"
						end

						return action .. "<i> Synced\n" .. use(syncedText) .. "</i>"
					end),
					RichText = true,
					Color = Theme.Colors.TextDimmed,
					TextSize = Theme.TextSize.Small,
					TextXAlignment = Enum.TextXAlignment.Right,
					LineHeight = 1.2,
				},
			},
		},
		Container {
			Size = UDim2.fromScale(1, 0),
			[Children] = {
				List {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
				},
				TextButton {
					Text = "Disconnect",
					LayoutOrder = 2,
					Solid = true,

					Activated = function()
						props.App:disconnect()
						props.App:home()
					end,
				},
				IconButton {
					Icon = Assets.Icons.Settings,
					BackgroundActive = Computed(function(use)
						return use(props.App.settingsWidget) ~= nil
					end),
					Activated = function()
						props.App:settings()
					end,
					LayoutOrder = 1,
				},
				IconButton {
					Icon = Assets.Icons.Info,
					BackgroundActive = Computed(function(use)
						return use(projectDetailsWidget) ~= nil
					end),
					Activated = function()
						local widget = peek(projectDetailsWidget)

						if widget then
							widget:Destroy()
							widget = nil
						else
							widget = ProjectDetails {
								App = props.App,
								Project = props.Project,

								Closed = function()
									peek(projectDetailsWidget):Destroy()
									projectDetailsWidget:set(nil)
								end,
							}
						end

						projectDetailsWidget:set(widget)
					end,
					[Cleanup] = function()
						local widget = peek(projectDetailsWidget)

						if widget then
							widget:Destroy()
							widget = nil
						end

						disconnect()
						task.cancel(thread)
					end,
				},
			},
		},
	}
end

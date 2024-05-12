local RunService = game:GetService('RunService')

local plugin = script:FindFirstAncestorWhichIsA('Plugin')

local Argon = script:FindFirstAncestor('Argon')
local Packages = Argon.Packages
local Helpers = Argon.Helpers

local Components = script.Components
local Widgets = script.Widgets
local Pages = script.Pages

local Fusion = require(Packages.Fusion)
local Signal = require(Packages.Signal)

local manifest = require(Argon.manifest)
local Config = require(Argon.Config)
local Util = require(Argon.Util)
local Core = require(Argon.Core)
local describeChanges = require(Helpers.describeChanges)

local Assets = require(script.Assets)
local Loader = require(script.Loader)
local Theme = require(script.Theme)

local Toolbar = require(Components.Plugin.Toolbar)
local ToolbarButton = require(Components.Plugin.ToolbarButton)
local Widget = require(Components.Plugin.Widget)
local Container = require(Components.Container)
local Padding = require(Components.Padding)
local Image = require(Components.Image)
local Text = require(Components.Text)
local List = require(Components.List)

local NotConnected = require(Pages.NotConnected)
local Connecting = require(Pages.Connecting)
local Connected = require(Pages.Connected)
local Unavailable = require(Pages.Unavailable)
local Prompt = require(Pages.Prompt)
local Error = require(Pages.Error)

local Settings = require(Widgets.Settings)
local Help = require(Widgets.Help)

local New = Fusion.New
local Value = Fusion.Value
local Spring = Fusion.Spring
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children
local cleanup = Fusion.cleanup
local peek = Fusion.peek

local RECONNECT_INTERVAL = 5

local App = {}
App.__index = App

function App.new()
	Loader.load()

	local self = setmetatable({}, App)

	self.core = nil
	self.helpWidget = nil
	self.settingsWidget = nil
	self.lastUpdate = os.clock()
	self.onCanceled = Signal.new()

	self.host = Config:get('Host')
	self.port = Config:get('Port')

	self.lastSync = Value(os.time())
	self.lastSyncKind = Value('Unknown')
	self.rootSize = Value(Vector2.new(300, 200))
	self.icon = Value(Assets.Argon.Logo)
	self.pages = Value({})

	local isOpen = Value(false)

	local toolbarButton = ToolbarButton {
		Toolbar = Toolbar {
			Name = 'Dervex Tools',
		},
		Name = 'Argon',
		ToolTip = 'Open Argon UI',
		Image = self.icon,

		[OnEvent 'Click'] = function()
			isOpen:set(not peek(isOpen))
		end,
	}

	Widget {
		Name = 'Argon',
		InitialDockTo = Enum.InitialDockState.Float,
		MinimumSize = peek(self.rootSize),
		Enabled = isOpen,

		[OnChange 'Enabled'] = function(isEnabled)
			isOpen:set(isEnabled)
		end,
		[OnChange 'AbsoluteSize'] = function(size)
			self.rootSize:set(size)
		end,

		[Children] = self.pages,
	}

	plugin.Unloading:Once(Observer(isOpen):onChange(function()
		toolbarButton:SetActive(peek(isOpen))
		self:disconnect()
	end))

	toolbarButton:SetActive(peek(isOpen))

	if RunService:IsEdit() then
		self:home()

		if Config:get('AutoConnect') then
			self:connect()
		end
	else
		self:setPage(Unavailable())
	end

	return self
end

function App:setIcon(icon: ('Ok' | 'Warn' | 'Error')?)
	if icon == 'Ok' then
		self.icon:set(Assets.Argon.LogoOk)
	elseif icon == 'Warn' then
		self.icon:set(Assets.Argon.LogoWarn)
	elseif icon == 'Error' then
		self.icon:set(Assets.Argon.LogoError)
	else
		self.icon:set(Assets.Argon.Logo)
	end
end

function App:setPage(page)
	local pages = peek(self.pages)

	for id, child in pairs(pages) do
		if child._finished then
			page[id] = nil
			continue
		end

		task.spawn(function()
			child._destructor(child._value)
			child._finished = true
		end)
	end

	local transparency = Value(0)
	local size = Value(UDim2.fromScale(1, 1))

	page = Computed(function()
		return New 'CanvasGroup' {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundColor3 = Theme.Colors.Background,
			BorderSizePixel = 0,
			GroupTransparency = Spring(transparency, 25),
			Size = Spring(size, 5),
			[Children] = {
				List {
					VerticalAlignment = Enum.VerticalAlignment.Center,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Spacing = 8,
				},
				Padding {
					Padding = Theme.WidgetPadding,
				},
				Container {
					Size = UDim2.fromScale(1, 0),
					[Children] = {
						Image {
							Size = UDim2.fromOffset(155, 35),
							Image = Assets.Argon.Banner,
							ImageColor3 = Theme.Colors.Brand,
						},
						Text {
							AnchorPoint = Vector2.new(1, 1),
							Position = UDim2.new(1, -3, 1, 0),
							Text = `v{manifest.package.version}`,
							Color = Theme.Colors.TextDimmed,
							TextSize = Theme.TextSize.Small,
						},
					},
				},
				Container {
					Size = UDim2.fromScale(1, 0),
					[Children] = page,
				},
			},
		}
	end, function(page)
		if not page then
			return
		end

		for _, descendant in ipairs(page:GetDescendants()) do
			if descendant:IsA('GuiButton') then
				descendant.Active = false
			end
		end

		page.ZIndex = 2

		transparency:set(1)
		size:set(UDim2.fromScale(2, 1.2))
		task.wait(0.15)

		cleanup(page)
	end)

	pages[Util.generateGUID()] = page
	self.pages:set(pages)
end

function App:home()
	self.lastUpdate = os.clock()

	self:setPage(NotConnected {
		App = self,
		Host = self.host,
		Port = self.port,
	})

	self:setIcon()
end

function App:settings()
	if self.settingsWidget then
		self.settingsWidget:Destroy()
	end

	self.settingsWidget = Settings {
		Closed = function()
			self.settingsWidget:Destroy()
			self.settingsWidget = nil
		end,
	}
end

function App:help()
	if self.helpWidget then
		self.helpWidget:Destroy()
	end

	self.helpWidget = Help {
		Closed = function()
			self.helpWidget:Destroy()
			self.helpWidget = nil
		end,
	}
end

function App:connect()
	local project = Value({})
	local canceled = false
	local loading = true

	self.core = Core.new(self.host, self.port)

	task.spawn(function()
		task.wait(0.15)

		if not self:isConnected() and loading then
			self:setPage(Connecting {
				App = self,
			})
		end
	end)

	self.onCanceled:Once(function()
		canceled = true
	end)

	self.core:onPrompt(function(message, changes)
		loading = false

		local signal = Signal.new()
		local result = false

		self:setIcon('Warn')

		-- Prompt user to accept or reject incoming changes
		if changes then
			local options = { 'Accept', 'Diff', 'Cancel' }
			message = describeChanges(changes)

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			local choice = signal:Wait()

			while choice == 'Diff' do
				warn('This feature is not yet implemented')
				choice = signal:Wait()
			end

			result = choice == 'Accept'
		-- Prompt user whether to continue when server ID differs
		else
			local options = { 'Continue', 'Cancel' }

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			result = signal:Wait() == 'Continue'
		end

		if self.core.status == Core.Status.Connected then
			self:setPage(Connected {
				App = self,
				Project = project,
			})

			self:setIcon('Ok')
		end

		return result
	end)

	self.core:onReady(function(projectDetails)
		loading = false
		project:set(projectDetails)

		self.lastSync:set(os.time())
		self.lastSyncKind:set(Config:get('InitialSyncPriority'))

		self:setPage(Connected {
			App = self,
			Project = project,
		})

		self:setIcon('Ok')
	end)

	self.core:onSync(function(kind, data)
		self.lastSync:set(os.time())
		self.lastSyncKind:set(
			(kind == 'SyncChanges' or kind == 'SyncDetails') and 'Server'
				or kind == 'SyncbackChanges' and 'Client'
				or 'Unknown'
		)

		if kind == 'SyncDetails' then
			project:set(data)
		end
	end)

	self.core:run():catch(function(err)
		loading = false

		if Core.wasExitGraceful(err) or canceled then
			self:disconnect()
			self:home()
			return
		end

		self:setPage(Error {
			App = self,
			Message = err.message or tostring(err),
		})

		self:setIcon('Error')

		self:disconnect()

		if Config:get('AutoReconnect') then
			task.wait(RECONNECT_INTERVAL)

			if self.lastUpdate + RECONNECT_INTERVAL <= os.clock() then
				self:connect()
			end
		end
	end)
end

function App:disconnect(cancel: boolean?)
	self.lastUpdate = os.clock()

	if self.core then
		if cancel then
			self.onCanceled:Fire()
		end

		self.core:stop()
		self.core = nil
	end
end

function App:isConnected()
	return self.core and self.core.status == Core.Status.Connected
end

function App:setHost(host: string)
	self.host = host
end

function App:setPort(port: number)
	self.port = port
end

return App

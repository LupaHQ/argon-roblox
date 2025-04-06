local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")

local plugin = script:FindFirstAncestorWhichIsA("Plugin")

print(
	"[ARGON DEBUG] Hello from the past! Plugin version:",
	require(script:FindFirstAncestor("Argon").manifest).package.version
)

local Argon = script:FindFirstAncestor("Argon")
local Packages = Argon.Packages
local Helpers = Argon.Helpers

local Components = script.Components
local Widgets = script.Widgets
local Pages = script.Pages

local Fusion = require(Packages.Fusion)
local Value = Fusion.Value
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
local Spring = Fusion.Spring
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children
local cleanup = Fusion.cleanup
local peek = Fusion.peek

-- local RECONNECT_INTERVAL = Config:get("ReconnectInterval") or 5 -- Removed incorrect config get

local App = {}
App.__index = App

-- Logging method
function App:sendLog(message: string, level: string?)
	-- Only send if connected to the server and core exists
	if not peek(self.isServerConnected) or not self.core or not self.core.client then
		return
	end

	local logData = {
		timestamp = os.time(),
		message = message,
		type = level or "INFO",
	}

	-- Call the new method on the client object
	-- Use Promise:Catch to handle potential errors without spamming
	self.core.client:sendLog(logData):catch(function(err)
		-- Only log the error once if connection seems lost
		if peek(self.isServerConnected) then
			self.isServerConnected:set(false) -- Assume disconnected on send error
			warn("[ARGON] Failed to send log via Core Client:", err)
		end
	end)
end

function App.new()
	Loader.load()

	local self = setmetatable({}, App)

	self.core = nil
	self.lastUpdate = os.clock()
	self.onCanceled = Signal.new()

	self.host = Config:get("Host") or "localhost"
	self.port = Config:get("Port") or 8000 -- Correct default port
	self.isServerConnected = Value(false) -- Add connection state

	self.lastSync = Value(os.time())
	self.lastSyncKind = Value("Unknown")

	self.rootSize = Value(Vector2.new(300, 200))
	self.icon = Value(Assets.Argon.Logo)
	self.pages = Value({})

	self.settingsWidget = Value(nil)
	self.helpWidget = Value(nil)

	local isOpen = Value(false)

	local toolbarButton = ToolbarButton {
		Toolbar = Toolbar {
			Name = "Dervex Tools",
		},
		Name = "Argon",
		ToolTip = "Open Argon UI",
		Image = self.icon,

		[OnEvent "Click"] = function()
			isOpen:set(not peek(isOpen))
		end,
	}

	Widget {
		Name = "Argon",
		MinimumSize = peek(self.rootSize),
		Enabled = isOpen,

		[OnChange "Enabled"] = function(isEnabled)
			isOpen:set(isEnabled)
		end,
		[OnChange "AbsoluteSize"] = function(size)
			self.rootSize:set(size)
		end,

		[Children] = self.pages,
	}

	plugin.Unloading:Connect(Observer(isOpen):onChange(function()
		toolbarButton:SetActive(peek(isOpen))
	end))

	toolbarButton:SetActive(peek(isOpen))

	if RunService:IsEdit() then
		self:home()

		if Config:get("AutoConnect") then
			self:connect()
		end
	else
		self:setPage(Unavailable())
	end

	-- Setup log listener here to access self
	LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageOutput then
			self:sendLog(message, "INFO")
		elseif messageType == Enum.MessageType.MessageWarning then
			self:sendLog(message, "WARN")
		elseif messageType == Enum.MessageType.MessageError then
			self:sendLog(message, "ERROR")
		end
	end)

	return self
end

function App:setIcon(icon: ("Ok" | "Warn" | "Error")?)
	if icon == "Ok" then
		self.icon:set(Assets.Argon.LogoOk)
	elseif icon == "Warn" then
		self.icon:set(Assets.Argon.LogoWarn)
	elseif icon == "Error" then
		self.icon:set(Assets.Argon.LogoError)
	else
		self.icon:set(Assets.Argon.Logo)
	end
end

function App:setPage(page)
	local pages = peek(self.pages)

	for id, child in pages do
		if child._finished then
			page[id] = nil
			continue
		end

		task.spawn(function()
			child._destructor(child._value)
			child._finished = true
		end)
	end

	local size = Value(UDim2.fromScale(1, 1))

	-- Extremely hacky way to smoothly transition between pages
	page = Computed(function()
		return New "Frame" {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = Spring(size, 10),
			BackgroundColor3 = Theme.Colors.Background,
			BorderSizePixel = 0,
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

		local TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		TweenService:Create(page, TWEEN_INFO, { BackgroundTransparency = 1 }):Play()

		for _, descendant in page:GetDescendants() do
			local properties = {}

			if descendant:IsA("GuiObject") then
				if descendant:IsA("GuiButton") then
					descendant.Active = false
				end

				properties.BackgroundTransparency = 1

				if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
					properties.TextTransparency = 1
				elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
					properties.ImageTransparency = 1
				end
			end

			if descendant:IsA("UIStroke") then
				properties.Transparency = 1
			end

			if next(properties) then
				TweenService:Create(descendant, TWEEN_INFO, properties):Play()
			end
		end

		page.ZIndex = 2

		size:set(UDim2.fromScale(1.2, 1))

		task.wait(0.2)
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
	local widget = peek(self.settingsWidget)

	if widget then
		widget:Destroy()
		widget = nil
	else
		widget = Settings {
			Closed = function()
				peek(self.settingsWidget):Destroy()
				self.settingsWidget:set(nil)
			end,
		}
	end

	self.settingsWidget:set(widget)
end

function App:help()
	local widget = peek(self.helpWidget)

	if widget then
		widget:Destroy()
		widget = nil
	else
		widget = Help {
			Closed = function()
				peek(self.helpWidget):Destroy()
				self.helpWidget:set(nil)
			end,
		}
	end

	self.helpWidget:set(widget)
end

function App:connect()
	local project = Value({})
	local canceled = false
	local loading = true

	self:sendLog(string.format("[ARGON] Attempting to connect to server at %s:%d...", self.host, self.port), "INFO") -- This log won't send yet
	self.core = Core.new(self.host, self.port)

	task.spawn(function()
		task.wait(0.2)

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

		self:setIcon("Warn")

		-- Prompt user to accept or reject incoming changes
		if changes then
			local options = { "Accept", "Diff", "Cancel" }
			message = describeChanges(changes)

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			local choice = signal:Wait()

			while choice == "Diff" do
				warn("This feature is not yet implemented!")
				print("You can see raw changes here:", changes)
				choice = signal:Wait()
			end

			result = choice == "Accept"
		-- Prompt user whether to continue when server ID differs
		else
			local options = { "Continue", "Cancel" }

			self:setPage(Prompt {
				App = self,
				Message = message,
				Options = options,
				Signal = signal,
			})

			result = signal:Wait() == "Continue"
		end

		if self.core.status == Core.Status.Connected then
			self:setPage(Connected {
				App = self,
				Project = project,
			})

			self:setIcon("Ok")
		end

		return result
	end)

	self.core:onReady(function(projectDetails)
		loading = false
		project:set(projectDetails)

		self.lastSync:set(os.time())
		self.lastSyncKind:set(Config:get("InitialSyncPriority"))

		self.isServerConnected:set(true) -- <<< SET CONNECTED STATE HERE
		self:sendLog("[ARGON] Successfully connected to server and initialized project", "INFO")

		self:setPage(Connected {
			App = self,
			Project = project,
		})

		self:setIcon("Ok")
	end)

	self.core:onSync(function(kind, data)
		self.lastSync:set(os.time())
		self.lastSyncKind:set(
			(kind == "SyncChanges" or kind == "SyncDetails") and "Server"
				or kind == "SyncbackChanges" and "Client"
				or "None"
		)

		self:sendLog(string.format("[ARGON] Sync event: %s", kind), "INFO")

		if kind == "SyncDetails" then
			project:set(data)
			self:sendLog("[ARGON] Project details updated from sync", "INFO")
		end
	end)

	self.core:run():catch(function(err)
		loading = false
		self.isServerConnected:set(false) -- <<< SET DISCONNECTED STATE HERE

		if Core.wasExitGraceful(err) or canceled then
			self:sendLog("[ARGON] Connection closed gracefully", "INFO") -- This won't send
			self:disconnect() -- disconnect already sets state to false
			self:home()
			return
		end

		self:sendLog(string.format("[ARGON] Connection error: %s", err.message or tostring(err)), "ERROR") -- This won't send

		self:setPage(Error {
			App = self,
			Message = err.message or tostring(err),
		})

		self:setIcon("Error")

		self:disconnect() -- disconnect already sets state to false

		if Config:get("AutoReconnect") then
			task.wait(5) -- Using hardcoded 5 for now, maybe make this configurable?

			if self.lastUpdate + 5 <= os.clock() then
				self:sendLog("[ARGON] Attempting to reconnect...", "INFO") -- This won't send
				self:connect()
			end
		end
	end)
end

function App:disconnect(cancel: boolean?)
	self.lastUpdate = os.clock()
	self.isServerConnected:set(false) -- <<< SET DISCONNECTED STATE HERE

	if self.core then
		if cancel then
			self.onCanceled:Fire()
			self:sendLog("[ARGON] Connection canceled by user", "INFO") -- This won't send
		else
			self:sendLog("[ARGON] Disconnecting from server", "INFO") -- This won't send
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

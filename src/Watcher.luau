--!strict
local CollectionService = game:GetService("CollectionService")

local Argon = script:FindFirstAncestor("Lemonade")

local Signal = require(Argon.Packages.Signal)

local Types = require(Argon.Types)
local Log = require(Argon.Log)

type Watcher = typeof(setmetatable(
	{} :: {
		isActive: boolean,
		rootInstances: { Instance },
		connections: { [Instance]: { RBXScriptConnection } },
		tagConnections: { [string | CollectionService]: { RBXScriptConnection } },
		valueInstances: { [Instance]: boolean },
		signal: Signal.Signal,
	},
	{} :: WatcherImpl
))

type WatcherImpl = {
	__index: WatcherImpl,
	new: () -> Watcher,
	start: (self: Watcher, rootInstances: { Instance }) -> (),
	stop: (self: Watcher) -> (),
	listen: (self: Watcher) -> Types.WatcherEvent,
	restart: (self: Watcher, instances: { Instance }) -> (),
	__connectEvents: (self: Watcher, instance: Instance) -> (),
	__watchTag: (self: Watcher, tag: string) -> (),
	__unwatchTag: (self: Watcher, tag: string) -> (),
	__onAdded: (self: Watcher, instance: Instance) -> (),
	__onChanged: (self: Watcher, instance: Instance, property: string) -> (),
	__onRemoved: (self: Watcher, instance: Instance) -> (),
}

local Watcher: WatcherImpl = {} :: WatcherImpl
Watcher.__index = Watcher

function Watcher.new()
	return setmetatable({
		isActive = false,
		rootInstances = {},
		connections = {},
		tagConnections = {},
		valueInstances = {},
		signal = Signal.new(),
	}, Watcher)
end

function Watcher:start(rootInstances)
	Log.trace("Starting watcher..")

	self.isActive = true
	self.rootInstances = rootInstances

	for _, instance in rootInstances do
		self:__connectEvents(instance)

		for _, descendant in instance:GetDescendants() do
			self:__connectEvents(descendant)
		end
	end

	local tagConnections = {}

	table.insert(
		tagConnections,
		CollectionService.TagAdded:Connect(function(tag)
			self:__watchTag(tag)

			for _, instance in CollectionService:GetTagged(tag) do
				self:__onChanged(instance, "Tags")
			end
		end)
	)

	table.insert(
		tagConnections,
		CollectionService.TagRemoved:Connect(function(tag)
			self:__unwatchTag(tag)
		end)
	)

	self.tagConnections[CollectionService] = tagConnections
end

function Watcher:stop()
	Log.trace("Stopping watcher..")

	for _, connections in self.connections do
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	for _, tagConnections in self.tagConnections do
		for _, tagConnection in tagConnections do
			tagConnection:Disconnect()
		end
	end

	self.isActive = false
	self.rootInstances = {}
	self.connections = {}
	self.tagConnections = {}
	self.valueInstances = {}
end

function Watcher:restart(instances)
	if not self.isActive then
		return
	end

	Log.trace("Restarting watcher..")

	self:stop()
	self:start(instances)
end

function Watcher:listen()
	return self.signal:Wait()
end

function Watcher:__connectEvents(instance)
	if instance == workspace.CurrentCamera then
		return
	end

	local connections = {}

	table.insert(
		connections,
		instance.ChildAdded:Connect(function(child)
			self:__onAdded(child)
		end)
	)

	table.insert(
		connections,
		instance.ChildRemoved:Connect(function(child)
			self:__onRemoved(child)
		end)
	)

	if not instance:IsA("ValueBase") then
		table.insert(
			connections,
			instance.Changed:Connect(function(property)
				if property ~= "Parent" then
					self:__onChanged(instance, property)
				end
			end)
		)
	else
		self.valueInstances[instance] = true

		table.insert(
			connections,
			instance.Changed:Connect(function(_value)
				self:__onChanged(instance, "Value")
			end)
		)

		table.insert(
			connections,
			instance.AttributeChanged:Connect(function(_attribute)
				self:__onChanged(instance, "Attributes")
			end)
		)

		for _, tag in instance:GetTags() do
			self:__watchTag(tag)
		end
	end

	self.connections[instance] = connections
end

function Watcher:__watchTag(tag)
	if self.tagConnections[tag] then
		return
	end

	local tagConnections = {}

	table.insert(
		tagConnections,
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
			if self.valueInstances[instance] then
				self:__onChanged(instance, "Tags")
			end
		end)
	)

	table.insert(
		tagConnections,
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
			if self.valueInstances[instance] then
				self:__onChanged(instance, "Tags")
			end
		end)
	)

	self.tagConnections[tag] = tagConnections
end

function Watcher:__unwatchTag(tag)
	local tagConnections = self.tagConnections[tag]

	if tagConnections then
		for _, tagConnection in tagConnections do
			tagConnection:Disconnect()
		end

		self.tagConnections[tag] = nil
	end
end

function Watcher:__onAdded(instance)
	self:__connectEvents(instance)

	self.signal:Fire({
		kind = "Add",
		instance = instance,
	})
end

function Watcher:__onChanged(instance, property)
	self.signal:Fire({
		kind = "Change",
		instance = instance,
		property = property,
	})
end

function Watcher:__onRemoved(instance)
	local connections = self.connections[instance]

	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end

		self.connections[instance] = nil
	end

	if self.valueInstances[instance] then
		self.valueInstances[instance] = nil
	end

	self.signal:Fire({
		kind = "Remove",
		instance = instance,
	})
end

return Watcher

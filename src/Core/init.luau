local ScriptEditorService = game:GetService("ScriptEditorService")
local RunService = game:GetService("RunService")

local Argon = script:FindFirstAncestor("Lemonade")

local Promise = require(Argon.Packages.Promise)

local Client = require(Argon.Client)
local Config = require(Argon.Config)
local Log = require(Argon.Log)
local Util = require(Argon.Util)
local Types = require(Argon.Types)
local Watcher = require(Argon.Watcher)
local Executor = require(Argon.Executor)
local SemVer = require(Argon.SemVer)
local manifest = require(Argon.manifest)
local equals = require(Argon.Helpers.equals)

local Processor = require(script.Processor)
local Changes = require(script.Changes)
local Tree = require(script.Tree)
local Error = require(script.Error)

local SYNCBACK_RATE = 0.5
local SYNCBACK_DEBOUNCE = 0.01

local Core = {
	Status = {
		Disconnected = 0,
		Connecting = 1,
		Connected = 2,
		Disconnecting = 3,
	},
}
Core.__index = Core

function Core.new(host: string?, port: string?)
	local self = setmetatable({}, Core)

	self.project = nil
	self.rootInstances = {}
	self.connections = {}
	self.status = 0
	self.lastSync = os.clock()
	self.alreadySentGameStarted = false

	self.tree = Tree.new()
	self.client = Client.new(host or Config:get("Host"), port or Config:get("Port"))
	self.processor = Processor.new(self.tree, self.client)
	self.watcher = Watcher.new()
	self.executor = Executor.new()

	self.__prompt = function(_message: string, _changes: Types.Changes?): boolean
		return true
	end
	self.__ready = function(_project: Types.Project) end
	self.__sync = function(_kind: Types.MessageKind, _data: any) end

	self:__handleOpenInEditor(Config:get("OpenInEditor"))

	-- watch for `OpenInEditor setting
	table.insert(
		self.connections,
		Config:onChanged("OpenInEditor", function(enabled)
			self:__handleOpenInEditor(enabled)
		end)
	)

	-- watch for `TwoWaySync` setting
	table.insert(
		self.connections,
		Config:onChanged("TwoWaySync", function(enabled)
			if enabled then
				self.watcher:start(self.rootInstances)
			else
				self.watcher:stop()
			end
		end)
	)

	return self
end

function Core:run(): Promise.Promise
	return Promise.new(function(_, reject)
		self.status = Core.Status.Connecting
		self.alreadySentGameStarted = false

		local initialSyncPriority = Config:get("InitialSyncPriority")

		Log.trace("Fetching server details..")

		local project = self.client:fetchDetails():expect()
		self.project = project

		self:__verifyProject(project, true):expect()

		Log.trace("Subscribing to the server queue..")

		self.client:subscribe():expect()

		Log.trace("Getting initial snapshot..")

		local snapshot = self.client:getSnapshot():expect()

		Log.trace("Initializing processor..")

		local changes = self.processor:init(snapshot, initialSyncPriority)

		if self.status ~= Core.Status.Connecting then
			return reject(Error.new(Error.Terminated))
		end

		for i, id in project.rootRefs do
			self.rootInstances[i] = self.tree:getInstance(id)
		end

		if initialSyncPriority ~= "None" then
			Log.trace("Processing initial snapshot..")

			if initialSyncPriority == "Server" then
				self:__verifyChanges(changes, true):expect()
				self.processor.write:applyChanges(changes, true)
			elseif changes:total() > 0 then
				local reversed = self.processor:reverseChanges(changes)
				self.client:write(reversed):expect()
			end
		end

		if Config:get("TwoWaySync") then
			self.watcher:start(self.rootInstances)
		end

		self.status = Core.Status.Connected
		self.__ready(project)

		Log.trace("Starting sync loops..")

		-- Set up run state detection with server script (required because plugins don't run during game execution)
		Log.info("[GameStartDetection] Setting up game start detection...")

		-- Reset detection flag
		self.alreadySentGameStarted = false

		-- Cleanup any existing detectors
		for _, name in { "_ARGON_GAME_START", "GameStartDetector", "GameStartDetector_SSS", "_ARGON_CENTRAL_PRINTER" } do
			local existing = game:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end

			local existingSSS = game:GetService("ServerScriptService"):FindFirstChild(name)
			if existingSSS then
				existingSSS:Destroy()
			end
		end

		-- Create a single detector script with highest priority
		local detector = Instance.new("Script")
		detector.Name = "_ARGON_GAME_START"
		detector.Source = [[
			-- CRITICAL: Only execute this code once per server
			if _G._ARGON_MARKER_PRINTED then
				script:Destroy()
				return
			end
			
			-- Mark as executed immediately
			_G._ARGON_MARKER_PRINTED = true
			
			-- CRITICAL: This exact message pattern is detected by the Argon server
			print("[GAME START DETECTOR] Game is running, firing event...")
			
			-- Create marker for debugging purposes
			local marker = Instance.new("BoolValue")
			marker.Name = "_ARGON_DETECTOR_RAN"
			marker.Value = true
			marker.Parent = game
			
			-- Clean up
			script:Destroy()
		]]
		detector.RunContext = Enum.RunContext.Server
		detector.Parent = game

		-- Fallback detection using RunService in the plugin
		local runStateConnection = RunService:GetPropertyChangedSignal("RunState"):Connect(function()
			if self.status ~= Core.Status.Connected then
				return
			end

			-- Just set the flag when game is running (but don't print from plugin)
			if RunService:IsRunning() and not self.alreadySentGameStarted then
				Log.info("[GameStartDetection] Game is running, detected via RunState change!")
				self.alreadySentGameStarted = true
			end
		end)

		table.insert(self.connections, runStateConnection)

		self:__startSyncbackLoop():catch(function(err)
			return reject(err)
		end)

		return self:__startSyncLoop():expect()
	end)
end

function Core:stop()
	Log.trace("Stopping Argon core..")

	self.status = Core.Status.Disconnecting

	self.watcher:stop()

	if self.client.isSubscribed then
		task.spawn(function()
			self.client:unsubscribe():catch(function(err)
				Log.info("Failed to unsubscribe from the server:", err)
			end)
		end)
	end

	Util.clean(self.connections)
end

function Core:onPrompt(callback: (message: string, changes: Types.Changes?) -> boolean)
	self.__prompt = function(message, changes)
		if self.status == Core.Status.Disconnecting then
			return false
		end

		return callback(message, changes)
	end
end

function Core:onReady(callback: (project: Types.Project) -> ())
	self.__ready = function(project)
		if self.status == Core.Status.Disconnecting then
			return
		end

		return callback(project)
	end
end

function Core:onSync(callback: (kind: Types.MessageKind, data: any) -> ())
	self.__sync = function(kind, data)
		if self.status == Core.Status.Disconnecting then
			return
		end

		return callback(kind, data)
	end
end

function Core.wasExitGraceful(err: Error.Error)
	return err == Error.GameId or err == Error.PlaceIds or err == Error.TooManyChanges or err == Error.Terminated
end

-- Internal functions

function Core:__verifyProject(project: Types.Project, initial: boolean?): Promise.Promise
	if not self:__shouldPrompt(initial) then
		return Promise.resolve()
	end

	if project.gameId and project.gameId ~= game.GameId then
		local err = Error.new(Error.GameId, game.GameId, project.gameId)

		if not self.__prompt(err.message) then
			return Promise.reject(err)
		end
	end

	if #project.placeIds > 0 and not table.find(project.placeIds, game.PlaceId) then
		local err = Error.new(Error.PlaceIds, game.PlaceId, project.placeIds)

		if not self.__prompt(err.message) then
			return Promise.reject(err)
		end
	end

	if not SemVer.parse(project.version):isCompatible(SemVer.parse(manifest.package.version)) then
		local err = Error.new(Error.Version, manifest.package.version, project.version)

		return Promise.reject(err)
	end

	return Promise.resolve()
end

function Core:__verifyChanges(changes: Types.Changes, initial: boolean?): Promise.Promise
	if not self:__shouldPrompt(initial) then
		return Promise.resolve()
	end

	if Changes.Total(changes) > Config:get("ChangesThreshold") then
		local err = Error.new(Error.TooManyChanges, #changes.additions, #changes.updates, #changes.removals)

		if not self.__prompt(err.message, changes) then
			return Promise.reject(err)
		end
	end

	return Promise.resolve()
end

function Core:__startSyncLoop()
	return Promise.new(function(resolve, reject)
		while self.status == Core.Status.Connected do
			local message = self.client:read():expect() :: Types.Message?

			if not message then
				continue
			end

			local kind = next(message) :: Types.MessageKind
			local data = message[kind] :: any

			Log.trace("Received message:", kind)

			if kind == "SyncChanges" then
				self:__verifyChanges(data):expect()

				self.processor.write:applyChanges(data)
				self.lastSync = os.clock()

				self.__sync(kind, data)
			elseif kind == "SyncDetails" then
				self:__verifyProject(data):expect()

				if not equals(self.project.rootRefs, data.rootRefs) then
					self.rootInstances = {}

					for i, id in data.rootRefs do
						self.rootInstances[i] = self.tree:getInstance(id)
					end

					self.watcher:restart(self.rootInstances)
				end

				self.project = data

				self.__sync(kind, data)
			elseif kind == "ExecuteCode" then
				self.executor:execute(data.code)
			elseif kind == "Disconnect" then
				reject(Error.new(Error.Disconnected, data.message))
			else
				local err = Error.new(Error.UnknownEvent, kind, data)
				Log.warn(err)
			end
		end

		resolve()
	end)
end

function Core:__startSyncbackLoop()
	local aggregateChanges = Changes.new()

	return Promise.new(function(resolve)
		task.spawn(function()
			while self.status == Core.Status.Connected do
				task.wait(SYNCBACK_RATE)

				if aggregateChanges:isEmpty() then
					continue
				end

				local changes = aggregateChanges
				aggregateChanges = Changes.new()

				self.client:write(changes):catch(function(err)
					Log.warn("Failed to write changes to the server:", err)
				end)

				self.__sync("SyncbackChanges", changes)
			end
		end)

		while self.status == Core.Status.Connected do
			local event = self.watcher:listen() :: Types.WatcherEvent

			if os.clock() - self.lastSync <= SYNCBACK_DEBOUNCE then
				continue
			end

			local kind = event.kind
			local changes = Changes.new()

			Log.trace("Received event:", kind)

			if kind == "Add" then
				local snapshot = self.processor.read:onAdd(event.instance)

				if snapshot then
					changes:add(snapshot)
				end
			elseif kind == "Change" then
				local snapshot = self.processor.read:onChange(event.instance, event.property)

				if snapshot then
					changes:update(snapshot)
				end
			elseif kind == "Remove" then
				local id = self.processor.read:onRemove(event.instance)

				if id then
					changes:remove(id)
				end
			end

			aggregateChanges:join(changes)
		end

		resolve()
	end)
end

function Core:__handleOpenInEditor(enabled: boolean)
	if not enabled then
		local connection = self.connections["openInEditor"]

		if connection then
			connection:Disconnect()
			self.connections["openInEditor"] = nil
		end

		return
	end

	self.connections["openInEditor"] = ScriptEditorService.TextDocumentDidOpen:Connect(function(document)
		if self.status ~= Core.Status.Connected then
			return
		end

		if document:IsCommandBar() then
			Log.trace("Document is a command bar, ignoring")
			return
		end

		local id = self.tree:getId(document:GetScript())

		if not id then
			Log.trace("Document is not synced by Argon, ignoring")
			return
		end

		local line = document:GetSelectionStart()

		self.client
			:open(id, line)
			:andThen(function()
				document:CloseAsync()
			end)
			:catch(function(err)
				Log.debug("Failed to open document in editor:", err)
			end)
	end)
end

function Core:__cleanConnection(id: string)
	local connection = self.connections[id]

	if connection then
		connection:Disconnect()
		self.connections[id] = nil
	end
end

function Core:__shouldPrompt(initial: boolean?): boolean
	local mode = Config:get("DisplayPrompts")

	if mode == "Always" then
		return true
	elseif mode == "Initial" and initial then
		return true
	else
		return false
	end
end

function Core:openInEditor(path: string): Promise.Promise
	if not Config:get("OpenInEditor") then
		return Promise.resolve()
	end

	return Promise.new(function(resolve, reject)
		self.client
			:postJson("/edit", {
				path = path,
			})
			:andThen(function(response)
				resolve(response)
			end)
			:catch(function(err)
				Log.info("Failed to open document in editor:", err)
				reject(err)
			end)
	end)
end

return Core

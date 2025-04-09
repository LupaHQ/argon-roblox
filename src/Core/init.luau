local ScriptEditorService = game:GetService("ScriptEditorService")
local RunService = game:GetService("RunService")

local Argon = script:FindFirstAncestor("Argon")

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
	Log.warn("--- Core:run START ---") -- Log start of run
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

		-- Set up run state detection with the most reliable approach
		Log.info("[GameStartDetection] Setting up game start detection...")

		-- Initial diagnostic
		Log.warn(
			"[DEBUG] Initial RunService state - IsRunning: "
				.. tostring(RunService:IsRunning())
				.. ", IsStudio: "
				.. tostring(RunService:IsStudio())
				.. ", IsServer: "
				.. tostring(RunService:IsServer())
		)

		-- Check if a detector script already exists and remove it
		Log.warn("[GameStartDetection] Checking for existing detector script...") -- Log check
		local existingScript = game:GetService("ServerScriptService"):FindFirstChild("GameStartDetector")
		Log.warn("[GameStartDetection] FindFirstChild result:", existingScript) -- Log result
		if existingScript then
			Log.warn("[GameStartDetection] Found existing detector script, removing it first")
			existingScript:Destroy()
		end

		-- Create a script to run in the server context
		-- This is important because plugin scripts run in a separate context that may not get the proper RunService events
		local serverDetectionScript = Instance.new("Script")
		serverDetectionScript.Name = "GameStartDetector"

		-- This script will fire a BindableEvent when the game starts running
		local gameStartedEvent = Instance.new("BindableEvent")
		gameStartedEvent.Name = "GameStartedEvent"
		gameStartedEvent.Parent = serverDetectionScript

		-- Set up the code for the server script
		serverDetectionScript.Source = [[
			local RunService = game:GetService("RunService")
			local ServerStorage = game:GetService("ServerStorage")
			local gameStartedEvent = script:WaitForChild("GameStartedEvent")
			
			local FLAG_NAME = "_ARGON_GAME_START_RUNNING"
			local cleanupConnection -- Forward declare

			-- Function to clean up the flag and connections
			local function cleanup()
				print("[GAME START DETECTOR SCRIPT] Cleanup called.")
				local flag = ServerStorage:FindFirstChild(FLAG_NAME)
				if flag then
					print("[GAME START DETECTOR SCRIPT] Destroying flag.")
					flag:Destroy()
				end
				if cleanupConnection then
					cleanupConnection:Disconnect()
					cleanupConnection = nil
				end
			end

			-- Singleton Check
			if ServerStorage:FindFirstChild(FLAG_NAME) then
				print("[GAME START DETECTOR SCRIPT] Another detector is already running (flag exists). Exiting script.")
				script:Destroy() -- Destroy this redundant script instance
				return
			end

			-- Create and set the flag
			print("[GAME START DETECTOR SCRIPT] Creating singleton flag.")
			local runningFlag = Instance.new("BoolValue")
			runningFlag.Name = FLAG_NAME
			runningFlag.Parent = ServerStorage

			local sentNotification = false
			local simConnection
			
			print("[GAME START DETECTOR SCRIPT] Initializing detection using PreSimulation. sentNotification=", sentNotification)

			-- Use PreSimulation
			simConnection = RunService.PreSimulation:Connect(function()
				if sentNotification then 
					-- Already fired, disconnect if somehow still connected
					if simConnection then simConnection:Disconnect() simConnection = nil cleanup() end 
					return 
				end

				task.wait(0.5) 
				print("[GAME START DETECTOR SCRIPT] Waited 0.5s. Setting sentNotification=true")
				sentNotification = true
				print("[GAME START DETECTOR SCRIPT] Game is running, firing event...")
				gameStartedEvent:Fire()
				
				-- Disconnect and cleanup *after* firing
				if simConnection then
					print("[GAME START DETECTOR SCRIPT] Disconnecting PreSimulation connection after fire.")
					simConnection:Disconnect()
					simConnection = nil
					cleanup() -- Explicitly call cleanup after firing
				end
			end)

			-- Clean up when script is destroyed
			cleanupConnection = script.Destroying:Connect(function()
				print("[GAME START DETECTOR SCRIPT] Destroying event triggered. Cleaning up...")
				if simConnection then
					simConnection:Disconnect()
					simConnection = nil
				end
				cleanup() -- Call cleanup on destroy
			end)

			print("[GAME START DETECTOR SCRIPT] Detection setup complete.")
		]]

		serverDetectionScript.Parent = game:GetService("ServerScriptService")

		-- Connect to the event
		local eventConnection = gameStartedEvent.Event:Connect(function()
			Log.warn(
				"[DEBUG] 🎮 Game start detected via server script's BindableEvent. Marker log should have been sent."
			)

			-- Send the game started event to the server
			if not self.alreadySentGameStarted then
				self.alreadySentGameStarted = true
				self.client:sendGameStartedEvent():catch(function(err)
					Log.warn("[DEBUG] ❌ Failed to send game started event:", err)
					self.alreadySentGameStarted = false
				end)
			end
		end)

		-- Also try direct RunState monitoring as backup (remove send event call)
		local runStateConnection = RunService:GetPropertyChangedSignal("RunState"):Connect(function()
			if self.status ~= Core.Status.Connected then
				return
			end

			Log.warn("[DEBUG] 🔄 RunState changed to: " .. tostring(RunService.RunState))

			-- Check if we should try sending the event again
			if RunService:IsRunning() and not self.alreadySentGameStarted then
				Log.warn("[DEBUG] 🔄 Game is now running, attempting to send game started event...")
				self.alreadySentGameStarted = true
				self.client:sendGameStartedEvent():catch(function(err)
					Log.warn("[DEBUG] ❌ Failed to send game started event:", err)
					self.alreadySentGameStarted = false
				end)
			end
		end)

		-- Cleanup function
		local function cleanupDetection()
			Log.warn("--- cleanupDetection CALLED ---") -- Log cleanup call
			if serverDetectionScript and serverDetectionScript.Parent then
				Log.warn("[GameStartDetection] cleanup: Destroying serverDetectionScript:", serverDetectionScript)
				serverDetectionScript:Destroy()
			end
			if eventConnection then
				Log.warn("[GameStartDetection] cleanup: Disconnecting eventConnection:", eventConnection)
				eventConnection:Disconnect()
			end

			-- Failsafe: Remove the singleton flag if it exists
			local flag = game:GetService("ServerStorage"):FindFirstChild("_ARGON_GAME_START_RUNNING")
			if flag then
				Log.warn("[GameStartDetection] cleanup: Failsafe - Removing singleton flag:", flag)
				flag:Destroy()
			end

			self.alreadySentGameStarted = false
		end

		-- Variable to track game start state
		-- local alreadySentGameStarted = false -- Remove this local declaration

		-- Diagnostic monitoring thread
		local debugConnection = task.spawn(function()
			while self.status == Core.Status.Connected do
				task.wait(5) -- Check every 5 seconds
				Log.debug(
					"[GameStartDetection] Status: hasStarted="
						.. tostring(self.alreadySentGameStarted)
						.. ", isRunning="
						.. tostring(RunService:IsRunning())
				)
			end
		end)

		-- Add to connections for cleanup
		table.insert(self.connections, {
			Disconnect = cleanupDetection,
		})
		table.insert(self.connections, runStateConnection)
		table.insert(self.connections, {
			Disconnect = function()
				task.cancel(debugConnection)
			end,
		})

		self:__startSyncbackLoop():catch(function(err)
			return reject(err)
		end)

		return self:__startSyncLoop():expect()
	end)
end

function Core:stop()
	Log.warn("--- Core:stop CALLED ---") -- Log stop call
	Log.trace("Stopping Argon core..")

	self.status = Core.Status.Disconnecting

	self.watcher:stop()

	if self.client.isSubscribed then
		task.spawn(function()
			self.client:unsubscribe():catch(function(err)
				Log.debug("Failed to unsubscribe from the server", err)
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

return Core

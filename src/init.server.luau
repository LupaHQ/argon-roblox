--!strict
-- local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

--[[ -- REMOVED THIS BLOCK TO ALLOW UI INITIALIZATION DURING RUNTIME
-- Don't initialize the plugin if already running - this prevents duplicate plugin instances
if RunService:IsRunning() then
	print("[ARGON] Game is already running, skipping plugin initialization")
	
	-- Set up logging for runtime (after play is pressed)
	local Config = require(script.Config)
	local Log = require(script.Log)
	-- local App = require(script.App) -- App wouldn't be fully initialized here
	
	Config.load()
	Log.debug("[ARGON] Plugin initialized in running mode - version 2.0.25")
	Log.__setLevel(Config:get("LogLevel"))
	
	-- Still capture logs when running
	LogService.MessageOut:Connect(function(message, messageType)
		local logLevel = "INFO"
		if messageType == Enum.MessageType.Warning then
			logLevel = "WARN"
		elseif messageType == Enum.MessageType.Error then
			logLevel = "ERROR"
		end
		
		-- Use a simpler approach to log to the output without going through the UI
		-- Log.__sendLog(message, logLevel) -- This depends on App.current which might not exist yet
		print("[LOG RUNTIME] " .. message) -- Fallback to simple print
	end)
	
	return
end
--]]

local Config = require(script.Config)
local Log = require(script.Log)
local App = require(script.App)

Config.load()
Log.__setLevel(Config:get("LogLevel"))

-- Initialize the App (UI) and store it in the App.current global
App.new()
-- local appInstance = App.new()  -- No need to store the instance locally if not used

-- Set up log forwarding AFTER App.new() is called so App.current exists
LogService.MessageOut:Connect(function(message, messageType)
	-- CRITICAL: Filter messages before processing to avoid spam
	if Log.shouldFilterMessage(message) then
		return
	end

	-- Check if App and App.current are valid before trying to send logs
	if App and App.current and App.current.sendLog then
		local logLevel = "INFO"
		-- Use direct value comparisons instead of enum
		-- Warning = 1, Error = 2, Output = 0
		if messageType.Value == 1 then -- Warning
			logLevel = "WARN"
		elseif messageType.Value == 2 then -- Error
			logLevel = "ERROR"
		end
		App.current:sendLog(message, logLevel)
	end
end)

Config:onChanged("LogLevel", function(level)
	Log.__setLevel(level)
end)

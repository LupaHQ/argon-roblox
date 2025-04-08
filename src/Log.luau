--!strict
local Argon = script:FindFirstAncestor("Argon")

local Util = require(Argon.Util)

-- Removing unused service
-- local LogService = game:GetService("LogService")

local App -- Forward declare App

local FILTERED_MESSAGES = {
	"logstreamer", -- Example, adapt based on your needs
	"messageout captured",
	"log received successfully",
	"session_start",
	"http requests can only be executed by game server",
	"failed to send to server",
	"http requests are disabled in studio",
	"server response:",
	"logstreamer script loaded",
	"logstreamer setup complete",
	"log fallback", -- Filter our own fallback message
	"game start detection", -- Filter internal detection logs
	"game started event", -- Filter event sending logs
	"clear logs request", -- Filter event sending logs
	"argon log", -- Filter our other fallback
	"successfully built project", -- Filter build messages
	"successfully connected to server", -- Common Argon log
	"runservice state", -- Filter debug logs
	"plugin initialized", -- Filter init logs
	"initializing plugin", -- Filter init logs
	"log clear success", -- Matches the success message tag
	"log clear failed", -- Matches the failure message tag
	"game start detected", -- Matches the detection message
	"[debug]", -- Catch common debug prefixes
}

local function format(...: any): string
	local args = ""

	for _, arg in { ... } do
		args ..= " " .. Util.stringify(arg)
	end

	return args
end

local Log = {
	Level = {
		Off = 0,
		Error = 1,
		Warn = 2,
		Info = 3,
		Debug = 4,
		Trace = 5,
	},
	__level = 2,
}

function Log.__setLevel(level: string)
	local num = Log.Level[level]

	if not num then
		Log.error("Invalid log level:", level)
	end

	Log.__level = num
end

function Log.trace(...: any)
	if Log.__level >= Log.Level.Trace then
		print("TRACE:" .. format(...))
	end
end

function Log.debug(...: any)
	if Log.__level >= Log.Level.Debug then
		print("DEBUG:" .. format(...))
	end
end

function Log.info(...: any)
	if Log.__level >= Log.Level.Info then
		print("INFO:" .. format(...))
	end
end

function Log.warn(...: any)
	if Log.__level >= Log.Level.Warn then
		warn("WARN:" .. format(...))
	end
end

function Log.error(...: any)
	if Log.__level >= Log.Level.Error then
		error("ERROR:" .. format(...), 0)
	end
end

-- Function to check if a message should be filtered
function Log.shouldFilterMessage(message: string): boolean
	message = message:lower()
	for _, filter in ipairs(FILTERED_MESSAGES) do
		if message:find(filter:lower()) then
			return true
		end
	end
	return false
end

-- Direct log sending function that bypasses UI for running mode
function Log.__sendLog(message: string, level: string)
	if Log.shouldFilterMessage(message) then
		return
	end -- Filter here too

	if not App or not App.current then
		-- Print to output if App is not available
		print("[ARGON LOG] " .. message)
		return
	end

	local client = App.current.client

	if client then
		client
			:sendLog({
				timestamp = os.time(),
				message = message,
				type = level,
			})
			:catch(function() end)
	end
end

return Log

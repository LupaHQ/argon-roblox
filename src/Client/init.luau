local Argon = script:FindFirstAncestor("Lemonade")

local Promise = require(Argon.Packages.Promise)

local Types = require(Argon.Types)
local Place = require(Argon.Place)
local Log = require(Argon.Log)

local Http = require(script.Http)
local Error = require(script.Error)

local function generateId(): number
	return math.floor(math.random() * 10 ^ 9)
end

local Client = {}
Client.__index = Client

function Client.new(host: string, port: number)
	local self = setmetatable({}, Client)

	self.isSubscribed = false
	self.clientId = generateId()
	self.placeName = Place.Name
	self.host = host
	self.port = port

	return self
end

function Client:getUrl(endpoint: string?): string
	local url = `http://{self.host}:{self.port}/{endpoint or ""}`
	return url
end

function Client:fetchDetails(): Promise.TypedPromise<Types.Project>
	Log.trace("Client request: details")

	local url = self:getUrl("details")

	return Http.get(url):andThen(function(response)
		return response:decode()
	end)
end

function Client:subscribe(): Promise.Promise
	Log.trace("Client request: subscribe")

	local url = self:getUrl("subscribe")

	return Http.post(url, {
		clientId = self.clientId,
		name = self.placeName,
	})
		:andThen(function()
			self.isSubscribed = true
		end)
		:catch(function(err)
			if err == Error.Unknown then
				return Promise.reject(Error.new(Error.AlreadySubscribed, self.clientId))
			else
				return Promise.reject(err)
			end
		end)
end

function Client:unsubscribe(): Promise.Promise
	Log.trace("Client request: unsubscribe")

	local url = self:getUrl("unsubscribe")

	return Http.post(url, {
		clientId = self.clientId,
	})
		:andThen(function()
			self.isSubscribed = false
		end)
		:catch(function(err)
			if err == Error.Unknown then
				return Promise.reject(Error.new(Error.NotSubscribed, self.clientId))
			else
				return Promise.reject(err)
			end
		end)
end

function Client:getSnapshot(instance: Types.Ref?): Promise.TypedPromise<Types.AddedSnapshot>
	Log.trace("Client request: snapshot")

	local url = self:getUrl("snapshot")

	return Http.post(url, {
		instance = instance or buffer.create(16),
	}):andThen(function(response)
		return response:decode()
	end)
end

function Client:read(): Promise.TypedPromise<Types.Message>
	Log.trace("Client request: read")

	local url = self:getUrl("read")

	return Http.post(url, {
		clientId = self.clientId,
	})
		:andThen(function(response)
			return response:decode()
		end)
		:catch(function(err)
			-- We don't need to handle this as Rust queue uses `recv_timeout`
			if err == Error.Timedout then
				return self:read()
			else
				return Promise.reject(err)
			end
		end)
end

function Client:write(changes: Types.Changes): Promise.Promise
	Log.trace("Client request: write")

	local url = self:getUrl("write")

	return Http.post(url, {
		clientId = self.clientId,
		changes = changes,
	})
end

function Client:sendLog(logData: { timestamp: number, message: string, type: string }): Promise.Promise
	Log.trace("Client request: log")

	local url = self:getUrl("log")

	-- Use Http.post, assuming it handles MsgPack encoding
	return Http.post(url, {
		clientId = self.clientId, -- Include clientId for potential future use/filtering
		timestamp = logData.timestamp,
		message = logData.message,
		type = logData.type,
	})
end

function Client:open(instance: Types.Ref, line: number): Promise.Promise
	Log.trace("Client request: open")

	local url = self:getUrl("open")

	return Http.post(url, {
		instance = instance,
		line = line,
	})
end

return Client

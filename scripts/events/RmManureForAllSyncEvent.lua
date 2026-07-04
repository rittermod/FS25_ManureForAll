-- RmManureForAllSyncEvent - Multiplayer sync event for ManureForAll
-- Author: Ritter
--
-- Description: Synchronizes manure production and husbandry storage state between server and clients

RmManureForAllSyncEvent = {}
local RmManureForAllSyncEvent_mt = Class(RmManureForAllSyncEvent, Event)
local Log = RmLogging.getLogger("ManureForAll")

InitEventClass(RmManureForAllSyncEvent, "RmManureForAllSyncEvent")

---Creates a new sync event
---@param data table Data to synchronize
---@return table
function RmManureForAllSyncEvent.new(data)
    local self = Event.new(RmManureForAllSyncEvent_mt)

    self.data = data or {}

    return self
end

---Registers the event class
function RmManureForAllSyncEvent.register()
    g_eventManager:registerEvent(RmManureForAllSyncEvent)
    Log:debug("RmManureForAllSyncEvent registered")
end

---Reads event data from network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmManureForAllSyncEvent:readStream(streamId, connection)
    -- Read data from stream
    -- Example: self.data.value = streamReadFloat32(streamId)

    self:run(connection)
end

---Writes event data to network stream
---@param streamId number Network stream ID
---@param connection table Network connection
function RmManureForAllSyncEvent:writeStream(streamId, connection)
    -- Write data to stream
    -- Example: streamWriteFloat32(streamId, self.data.value)
end

---Executes the event
---@param connection table Network connection
function RmManureForAllSyncEvent:run(connection)
    -- Apply the synchronized data
    if RmManureForAll and RmManureForAll.onSyncReceived then
        RmManureForAll:onSyncReceived(self.data)
    end

    -- If server, broadcast to all clients
    if g_server ~= nil and connection ~= nil then
        g_server:broadcastEvent(RmManureForAllSyncEvent.new(self.data), nil, connection)
    end
end

---Sends sync event from client to server
---@param data table Data to synchronize
function RmManureForAllSyncEvent.sendToServer(data)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(RmManureForAllSyncEvent.new(data))
    end
end

---Broadcasts sync event from server to all clients
---@param data table Data to synchronize
---@param excludeConnection table Optional connection to exclude
function RmManureForAllSyncEvent.broadcastFromServer(data, excludeConnection)
    if g_server ~= nil then
        g_server:broadcastEvent(RmManureForAllSyncEvent.new(data), nil, excludeConnection)
    end
end

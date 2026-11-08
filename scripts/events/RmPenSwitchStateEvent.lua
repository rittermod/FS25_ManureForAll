--[[
    RmPenSwitchStateEvent.lua

    Server -> client: the full set of switched-off pens, one node object each. The receiver
    rebuilds its flags from the list (RmPenSwitch.rebuildFromList). Sent to every client after a
    change and to each joining client from the late-join hook. One-way: dropped on the server.

    Author: Ritter
]]

RmPenSwitchStateEvent = {}
local RmPenSwitchStateEvent_mt = Class(RmPenSwitchStateEvent, Event)
InitEventClass(RmPenSwitchStateEvent, "RmPenSwitchStateEvent")

local Log = RmLogging.getLogger("ManureForAll")

---Peer seam: true on the server. Suites swap it to drive the client branch.
---@return boolean
function RmPenSwitchStateEvent.isServer()
    return g_server ~= nil
end

---Empty event for the receiver.
---@return table self
function RmPenSwitchStateEvent.emptyNew()
    local self = Event.new(RmPenSwitchStateEvent_mt)
    self.pens = {}
    return self
end

---Event carrying the switched-off pens.
---@param pens table array of placeables
---@return table self
function RmPenSwitchStateEvent.new(pens)
    local self = RmPenSwitchStateEvent.emptyNew()
    self.pens = pens or {}
    return self
end

---True for a pen that can travel as a node object.
---@param pen table|nil
---@return boolean
local function isSendable(pen)
    return pen ~= nil and pen.isDeleted ~= true and NetworkUtil.getObjectId(pen) ~= nil
end

---Write a UInt16 count of the sendable pens, then one node object each.
---@param streamId integer
---@param connection table
function RmPenSwitchStateEvent:writeStream(streamId, connection)
    local resolved = {}
    for _, pen in ipairs(self.pens) do
        if isSendable(pen) then
            resolved[#resolved + 1] = pen
        else
            Log:warning("state event: a switched-off pen is deleted or unregistered - not sent")
        end
    end
    streamWriteUInt16(streamId, #resolved)
    for _, pen in ipairs(resolved) do
        NetworkUtil.writeNodeObject(streamId, pen)
    end
    Log:trace("state event: wrote %d/%d pen(s)", #resolved, #self.pens)
end

---Read the count-framed list; an unresolvable node object is skipped with its id consumed.
---@param streamId integer
---@param connection table
function RmPenSwitchStateEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    self.pens = {}
    for i = 1, count do
        local pen = NetworkUtil.readNodeObject(streamId)
        if pen == nil then
            Log:warning("state event: pen %s/%s did not resolve on read - skipped", tostring(i), tostring(count))
        else
            self.pens[#self.pens + 1] = pen
        end
    end
    self:run(connection)
end

---Apply on a client: rebuild the flags. Dropped on the server.
---@param connection table
function RmPenSwitchStateEvent:run(connection)
    if RmPenSwitchStateEvent.isServer() then
        Log:warning("state event received on the server - dropped")
        return
    end
    RmPenSwitch.rebuildFromList(self.pens)
end

---Broadcast the full set to every client (server only).
function RmPenSwitchStateEvent.broadcastState()
    if not RmPenSwitchStateEvent.isServer() then
        Log:warning("broadcastState called on a client - not sent")
        return
    end
    local pens = RmPenSwitch.listDisabledPens()
    g_server:broadcastEvent(RmPenSwitchStateEvent.new(pens))
    Log:info("pen switch: broadcast %d switched-off pen(s)", #pens)
end

---Send the full set to one joining client (server only).
---@param connection table
function RmPenSwitchStateEvent.sendToConnection(connection)
    if not RmPenSwitchStateEvent.isServer() then
        return
    end
    local pens = RmPenSwitch.listDisabledPens()
    connection:sendEvent(RmPenSwitchStateEvent.new(pens))
    Log:info("pen switch: sent %d switched-off pen(s) to a joining client", #pens)
end

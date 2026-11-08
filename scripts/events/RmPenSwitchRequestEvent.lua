--[[
    RmPenSwitchRequestEvent.lua

    Client -> server: the switch ops a player made in the pen dialog, one node object and one
    bool each. The server re-checks master-user status, applies the net changes through
    RmPenSwitch.applyOps and broadcasts the full set when something changed. SP and the host
    apply directly through send() and broadcast without a local loop-back.

    Author: Ritter
]]

RmPenSwitchRequestEvent = {}
local RmPenSwitchRequestEvent_mt = Class(RmPenSwitchRequestEvent, Event)
InitEventClass(RmPenSwitchRequestEvent, "RmPenSwitchRequestEvent")

local Log = RmLogging.getLogger("ManureForAll")

---Peer seam: true on the server. Suites swap it to drive the client branch.
---@return boolean
function RmPenSwitchRequestEvent.isServer()
    return g_server ~= nil
end

---Empty event for the receiver.
---@return table self
function RmPenSwitchRequestEvent.emptyNew()
    local self = Event.new(RmPenSwitchRequestEvent_mt)
    self.ops = {}
    return self
end

---Event carrying switch ops.
---@param ops table array of { pen = placeable, disabled = boolean }
---@return table self
function RmPenSwitchRequestEvent.new(ops)
    local self = RmPenSwitchRequestEvent.emptyNew()
    self.ops = ops or {}
    return self
end

---True for a live pen of an injected type that is not being sold or deleted.
---@param pen table|nil
---@return boolean
local function isLivePen(pen)
    return pen ~= nil and pen.isDeleted ~= true and pen.markedForDeletion ~= true and RmPenSwitch.isGated(pen)
end

---Write a UInt16 count of the sendable ops, then a node object and a bool per op.
---@param streamId integer
---@param connection table
function RmPenSwitchRequestEvent:writeStream(streamId, connection)
    local resolved = {}
    for _, op in ipairs(self.ops) do
        if isLivePen(op.pen) and NetworkUtil.getObjectId(op.pen) ~= nil then
            resolved[#resolved + 1] = op
        else
            Log:warning("request event: an op's pen is gone, being sold, not switchable or unregistered - not sent")
        end
    end
    streamWriteUInt16(streamId, #resolved)
    for _, op in ipairs(resolved) do
        NetworkUtil.writeNodeObject(streamId, op.pen)
        streamWriteBool(streamId, op.disabled == true)
    end
    Log:trace("request event: wrote %d/%d op(s)", #resolved, #self.ops)
end

---Read the count-framed ops; an unresolvable pen stays as a nil op for validate to report.
---@param streamId integer
---@param connection table
function RmPenSwitchRequestEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    self.ops = {}
    for i = 1, count do
        local pen = NetworkUtil.readNodeObject(streamId)
        local disabled = streamReadBool(streamId)
        self.ops[#self.ops + 1] = { pen = pen, disabled = disabled, index = i }
    end
    self:run(connection)
end

---Check the sender and each op. A remote non-master sender is refused; dead pens are skipped.
---@param connection table|nil nil for the local authority (SP or host)
---@param ops table array of ops
---@return table|nil validOps nil when the request is refused
---@return string reason "ok" or "not master user"
function RmPenSwitchRequestEvent.validate(connection, ops)
    if connection ~= nil and not connection:getIsServer() then
        local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
        if userManager == nil or not userManager:getIsConnectionMasterUser(connection) then
            local user = userManager ~= nil and userManager:getUserByConnection(connection) or nil
            local userId = user ~= nil and user:getId() or nil
            local farm = (userId ~= nil and g_farmManager ~= nil) and g_farmManager:getFarmByUserId(userId) or nil
            Log:warning("pen switch request refused: user %s ('%s', farm %s) is not the master user",
                tostring(userId), tostring(user ~= nil and user:getNickname() or nil),
                tostring(farm ~= nil and farm.farmId or nil))
            return nil, "not master user"
        end
    end
    local valid = {}
    for i, op in ipairs(ops or {}) do
        if isLivePen(op.pen) then
            valid[#valid + 1] = op
        else
            Log:warning("pen switch request: op %s names no live pen - skipped", tostring(op.index or i))
        end
    end
    return valid, "ok"
end

---Server: validate, apply, broadcast the full set when anything changed. Dropped on a client.
---@param connection table
function RmPenSwitchRequestEvent:run(connection)
    if not RmPenSwitchRequestEvent.isServer() then
        Log:warning("pen switch request received on a client - dropped")
        return
    end
    local validOps = RmPenSwitchRequestEvent.validate(connection, self.ops)
    if validOps == nil then
        return
    end
    Log:info("pen switch: request with %d op(s), %d valid", #self.ops, #validOps)
    local applied = RmPenSwitch.applyOps(validOps)
    if applied > 0 then
        RmPenSwitchStateEvent.broadcastState()
    end
end

---Send switch ops: SP and the host apply directly; a pure client asks the server.
---@param ops table array of { pen = placeable, disabled = boolean }
---@return integer appliedCount 0 on a client (the server answers with the state event)
function RmPenSwitchRequestEvent.send(ops)
    if ops == nil or #ops == 0 then
        Log:debug("PENS: no ops to send")
        return 0
    end
    if RmPenSwitchRequestEvent.isServer() then
        local validOps = RmPenSwitchRequestEvent.validate(nil, ops)
        local applied = RmPenSwitch.applyOps(validOps)
        local mission = g_currentMission
        local isMultiplayer = mission ~= nil and mission.missionDynamicInfo ~= nil
            and mission.missionDynamicInfo.isMultiplayer == true
        if applied > 0 and isMultiplayer then
            RmPenSwitchStateEvent.broadcastState()
        end
        return applied
    end
    g_client:getServerConnection():sendEvent(RmPenSwitchRequestEvent.new(ops))
    Log:info("pen switch: sent %d op(s) to the server", #ops)
    return 0
end

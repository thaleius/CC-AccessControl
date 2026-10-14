-- lockdown_alarm.lua
-- Polls the auth server for lockdown state and drives a redstone output to
-- match. Deliberately FAILS CLOSED (alarm ON) when the server can't be
-- reached: for a security-signal device, "can't confirm lockdown is off"
-- is treated as a fault condition worth flagging, not a reason to go quiet.

os.loadAPI("config_util.lua")
local function runProgram()

------------- Config -------------
local defaults = {
  protocol        = "doorAuth.v1",
  server_name     = "DoorAuthServer",
  request_timeout = 3,
  poll_interval   = 2,
  output_side     = "back",
  emergency_input_side = "top",
  registration_secret = "change-me-registration-secret",
}

local fields = {
  {key="protocol", label="Rednet protocol"},
  {key="server_name", label="Server host name"},
  {key="request_timeout", label="Server request timeout (s)"},
  {key="poll_interval", label="Poll interval (s)"},
  {key="output_side", label="Redstone output side",
    help="A side name (top/bottom/left/right/front/back) or 'all'."},
  {key="emergency_input_side", label="Emergency button input side",
    help="A redstone button or lever on this side triggers lockdown."},
  {key="registration_secret", label="Emergency registration secret",
    help="Must match auth_server's registration_secret."},
}

local cfg = config_util.load("lockdown_alarm", defaults, fields, "Lockdown Alarm Config")

local PROTOCOL        = cfg.protocol
local SERVER_NAME       = cfg.server_name
local REQUEST_TIMEOUT   = cfg.request_timeout
local POLL_INTERVAL     = math.max(0.5, tonumber(cfg.poll_interval) or 2)
local OUTPUT_SIDE       = config_util.trim(cfg.output_side or "back"):lower()
local INPUT_SIDE        = config_util.trim(cfg.emergency_input_side or "top"):lower()
local REGISTRATION_SECRET = cfg.registration_secret
---------------------------------

local validSides = {}
for _, side in ipairs(rs.getSides()) do validSides[side] = true end
if OUTPUT_SIDE ~= "all" and not validSides[OUTPUT_SIDE] then
  print("[Alarm] Invalid output_side '"..OUTPUT_SIDE.."', falling back to 'back'.")
  OUTPUT_SIDE = "back"
end

local emergencyInputEnabled = validSides[INPUT_SIDE]
if not emergencyInputEnabled then
  print("[Alarm] Invalid emergency_input_side '"..INPUT_SIDE.."'; emergency trigger disabled.")
elseif OUTPUT_SIDE == "all" or OUTPUT_SIDE == INPUT_SIDE then
  print("[Alarm] Emergency input must be separate from the alarm output; emergency trigger disabled.")
  emergencyInputEnabled = false
end

local function setAlarm(active)
  if OUTPUT_SIDE == "all" then
    for _, side in ipairs(rs.getSides()) do
      pcall(redstone.setOutput, side, active)
    end
  else
    pcall(redstone.setOutput, OUTPUT_SIDE, active)
  end
end

local speaker = peripheral.find("speaker")
local alarmActive = true

local function makeSawtoothWave(frequency)
  local sampleRate = 48000
  local samples = {}
  for index = 0, sampleRate / 2 - 1 do
    local phase = (index * frequency / sampleRate) % 1
    samples[index + 1] = math.floor(phase * 255) - 127
  end
  return samples
end

local function waitForAudioChunk()
  local timer = os.startTimer(0.1)
  while alarmActive do
    local event, parameter = os.pullEvent()
    if event == "speaker_audio_empty" then return true end
    if event == "timer" and parameter == timer then return false end
  end
  return false
end

local function playAudioChunk(samples)
  while alarmActive do
    local ok, queued = pcall(speaker.playAudio, samples, 1)
    if not ok then return end
    if queued then
      while alarmActive do
        if waitForAudioChunk() then return end
      end
      return
    end
    waitForAudioChunk()
  end
end

local function requestStatus()
  local server = config_util.findServer(PROTOCOL, SERVER_NAME, 10)
  if not server then return nil, "Server offline." end

  rednet.send(server, {type="status"}, PROTOCOL)
  local id, msg = rednet.receive(PROTOCOL, REQUEST_TIMEOUT)
  if id ~= server or type(msg) ~= "table" or msg.type ~= "status_result" then
    return nil, "No response."
  end
  return msg
end

local function drawScreen(stateText, lockdown)
  term.clear()
  term.setCursorPos(1,1)
  print("=== DoorAuth Lockdown Alarm ===")
  print("Server:          "..SERVER_NAME)
  print("Protocol:        "..PROTOCOL)
  print("Output side:     "..OUTPUT_SIDE)
  print("Emergency input: "..(emergencyInputEnabled and INPUT_SIDE or "disabled"))
  print("Lockdown:        "..tostring(lockdown))
  print("Alarm:           "..stateText)
end

config_util.openModems()

-- Fail closed until we hear otherwise from the server.
setAlarm(true)
drawScreen("SIGNAL ON (no server contact yet)", "unknown")

local function statusLoop()
  while true do
    local msg, err = requestStatus()

    if msg and type(msg.lockdown) == "boolean" then
      alarmActive = msg.lockdown
      setAlarm(alarmActive)
      if not alarmActive and speaker then pcall(speaker.stop) end
      drawScreen(alarmActive and "SIGNAL ON" or "signal off", alarmActive)
    else
      alarmActive = true
      setAlarm(true)
      drawScreen("SIGNAL ON (server offline: "..tostring(err)..")", "unknown")
    end

    sleep(POLL_INTERVAL)
  end
end

local function sirenLoop()
  if not speaker then
    while true do sleep(60) end
  end

  local samples1960 = makeSawtoothWave(1960)
  local samples980 = makeSawtoothWave(980)
  while true do
    if alarmActive then
      for index = 1, 8 do
        if not alarmActive then break end
        playAudioChunk(index % 2 == 1 and samples1960 or samples980)
      end
      for _ = 1, 5 do
        if not alarmActive then break end
        playAudioChunk(samples980)
      end
    else
      sleep(0.1)
    end
  end
end

local function emergencyInputLoop()
  if not emergencyInputEnabled then
    while true do sleep(60) end
  end

  local wasPressed = redstone.getInput(INPUT_SIDE)
  local function sendEmergencyRequest()
    local server = config_util.findServer(PROTOCOL, SERVER_NAME, 10)
    if not server then return end
    rednet.send(server, {
      type="emergency_lockdown",
      secret=REGISTRATION_SECRET,
    }, PROTOCOL)
  end

  if wasPressed then sendEmergencyRequest() end
  while true do
    os.pullEvent("redstone")
    local isPressed = redstone.getInput(INPUT_SIDE)
    if isPressed and not wasPressed then sendEmergencyRequest() end
    wasPressed = isPressed
  end
end

parallel.waitForAny(statusLoop, emergencyInputLoop, sirenLoop)
end

config_util.runProtected(runProgram)

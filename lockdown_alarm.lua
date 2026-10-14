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
  alarm_tone = "classic",
  custom_sequence = "ramp 500 1800 saw 2; silence 1 | tone 880 sine 0.25; silence 0.75",
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
  {key="alarm_tone", label="Alarm sound (classic/alternating/rising/custom)",
    help="Choose classic, alternating, rising, or custom."},
  {key="custom_sequence", label="Custom sound sequence",
    help="Tracks separated by '|'; steps by ';'. Steps: tone <Hz> <wave> <seconds>, ramp <startHz> <endHz> <wave> <seconds>, silence <seconds>. Waves: sine, square, saw, triangle."},
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

local SAMPLE_RATE = 48000
local AUDIO_CHUNK_SECONDS = 0.5
local VALID_WAVES = {sine=true, square=true, saw=true, triangle=true}
local SINE_TABLE = {}
for index = 0, 255 do
  SINE_TABLE[index + 1] = math.sin(index * math.pi * 2 / 256)
end

local function parseSequence(sequenceText)
  local tracks = {}
  for trackText in (sequenceText.."|"):gmatch("(.-)|") do
    local track = {}
    for stepText in (trackText..";"):gmatch("(.-);") do
      local parts = {}
      for part in stepText:gmatch("%S+") do parts[#parts + 1] = part:lower() end
      if #parts > 0 then
        local step = {kind=parts[1]}
        if step.kind == "silence" and #parts == 2 then
          step.duration = tonumber(parts[2])
        elseif step.kind == "tone" and #parts == 4 then
          step.startFrequency = tonumber(parts[2])
          step.endFrequency = step.startFrequency
          step.wave = parts[3]
          step.duration = tonumber(parts[4])
        elseif step.kind == "ramp" and #parts == 5 then
          step.startFrequency = tonumber(parts[2])
          step.endFrequency = tonumber(parts[3])
          step.wave = parts[4]
          step.duration = tonumber(parts[5])
        else
          return nil, "Invalid step: "..stepText
        end

        if not step.duration or step.duration < 0.05 or step.duration > 30 then
          return nil, "Step duration must be between 0.05 and 30 seconds."
        end
        if step.kind ~= "silence" then
          if not VALID_WAVES[step.wave] then return nil, "Unknown wave: "..tostring(step.wave) end
          if not step.startFrequency or not step.endFrequency
            or step.startFrequency < 20 or step.startFrequency > 12000
            or step.endFrequency < 20 or step.endFrequency > 12000 then
            return nil, "Frequencies must be between 20 and 12000 Hz."
          end
        end
        track[#track + 1] = step
        if #track > 32 then return nil, "A track can contain at most 32 steps." end
      end
    end
    if #track > 0 then tracks[#tracks + 1] = track end
    if #tracks > 8 then return nil, "A sequence can contain at most 8 tracks." end
  end
  if #tracks == 0 then return nil, "The sequence is empty." end
  return tracks
end

local function getAlarmSequence()
  local presets = {
    classic = "tone 1960 saw 0.35; tone 980 saw 0.35; silence 0.15",
    alternating = "tone 1200 square 0.25; tone 1800 square 0.25; tone 2400 square 0.25; tone 1800 square 0.25; silence 0.2",
    rising = "ramp 450 1800 saw 2; silence 1",
  }
  local choice = config_util.trim(cfg.alarm_tone):lower()
  local sequenceText = presets[choice]
  if choice == "custom" then sequenceText = cfg.custom_sequence end
  if not sequenceText then
    print("[Alarm] Unknown alarm sound; using classic.")
    sequenceText = presets.classic
  end
  local sequence, err = parseSequence(sequenceText)
  if not sequence then
    print("[Alarm] Invalid sound sequence: "..err.." Using classic.")
    sequence = assert(parseSequence(presets.classic))
  end
  return sequence
end

local function waveSample(step, elapsed, phase)
  local progress = math.min(1, elapsed / step.duration)
  local frequency = step.startFrequency + (step.endFrequency - step.startFrequency) * progress
  phase = (phase + frequency / SAMPLE_RATE) % 1
  local value
  if step.wave == "sine" then
    value = SINE_TABLE[math.floor(phase * 256) + 1]
  elseif step.wave == "square" then
    value = phase < 0.5 and 1 or -1
  elseif step.wave == "triangle" then
    value = 1 - 4 * math.abs(phase - 0.5)
  else
    value = phase * 2 - 1
  end
  return value, phase
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

local function playSequence(tracks)
  local totalDurations = {}
  local cursors = {}
  local phases = {}
  for trackIndex, track in ipairs(tracks) do
    local totalDuration = 0
    for _, step in ipairs(track) do totalDuration = totalDuration + step.duration end
    totalDurations[trackIndex] = totalDuration
    cursors[trackIndex] = {stepIndex=1, stepStart=0, stepEnd=track[1].duration}
    phases[trackIndex] = 0
  end

  local sampleCount = math.floor(SAMPLE_RATE * AUDIO_CHUNK_SECONDS)
  local normalization = math.sqrt(#tracks)
  local elapsed = 0
  while alarmActive do
    local samples = {}
    for sampleIndex = 0, sampleCount - 1 do
      local sampleTime = elapsed + sampleIndex / SAMPLE_RATE
      local mixed = 0
      for trackIndex, track in ipairs(tracks) do
        local cursor = cursors[trackIndex]
        local trackTime = sampleTime % totalDurations[trackIndex]
        if trackTime < cursor.stepStart then
          cursor.stepIndex = 1
          cursor.stepStart = 0
          cursor.stepEnd = track[1].duration
        end
        while trackTime >= cursor.stepEnd do
          cursor.stepStart = cursor.stepEnd
          cursor.stepIndex = cursor.stepIndex + 1
          if cursor.stepIndex > #track then
            cursor.stepIndex = 1
            cursor.stepStart = 0
            cursor.stepEnd = track[1].duration
          else
            cursor.stepEnd = cursor.stepEnd + track[cursor.stepIndex].duration
          end
        end

        local step = track[cursor.stepIndex]
        if step.kind ~= "silence" then
          local value
          value, phases[trackIndex] = waveSample(step, trackTime - cursor.stepStart, phases[trackIndex])
          mixed = mixed + value
        end
      end
      mixed = mixed / normalization
      samples[sampleIndex + 1] = math.floor(math.max(-1, math.min(1, mixed)) * 127)
    end
    playAudioChunk(samples)
    elapsed = elapsed + AUDIO_CHUNK_SECONDS
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

  local tracks = getAlarmSequence()
  while true do
    if alarmActive then
      playSequence(tracks)
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

-- DoorAuth installer for CC:Tweaked.

local GITHUB_RAW_URL = "https://raw.githubusercontent.com/thaleius/CC-AccessControl/main/"
local DOWNLOADABLE_FILES = {
  ["config_util.lua"] = true,
  ["auth_server.lua"] = true,
  ["admin_remote.lua"] = true,
  ["door_controller.lua"] = true,
  ["door_fob.lua"] = true,
  ["keypad_door.lua"] = true,
  ["lockdown_alarm.lua"] = true,
  ["installer.lua"] = true,
}

local STARTUP_FILE = "startup.lua"
local STARTUP_MANIFEST = "doorauth_startup.txt"

local PROGRAM_FILES = {
  "auth_server.lua",
  "door_controller.lua",
  "keypad_door.lua",
  "admin_remote.lua",
  "door_fob.lua",
  "lockdown_alarm.lua",
}

local packages = {
  {name="Auth server", files={"auth_server.lua"}},
  {name="Door controller", files={"door_controller.lua"}},
  {name="Keypad", files={"keypad_door.lua"}},
  {name="Admin remote", files={"admin_remote.lua"}},
  {name="Door fob", files={"door_fob.lua"}},
  {name="Lockdown alarm", files={"lockdown_alarm.lua"}},
}

local function promptPackage()
  term.clear()
  term.setCursorPos(1, 1)
  print("=== DoorAuth Installer ===")
  print("Select the program for this computer:")
  for index, package in ipairs(packages) do
    print(("%d) %s"):format(index, package.name))
  end
  print("U) Update installed programs and installer")
  print("I) Update installer only")
  print("Q) Cancel")
  write("> ")

  local choice = read():lower()
  local index = tonumber(choice)
  if choice == "q" then return nil end
  if choice == "u" then return {name="Update installed files", update=true} end
  if choice == "i" then
    return {name="Update installer", updateInstaller=true, files={"installer.lua"}}
  end
  if index and packages[index] then return packages[index] end
  print("Invalid selection.")
  sleep(1)
  return promptPackage()
end

local function fetchFiles(files)
  local downloads = {}
  for _, filename in ipairs(files) do
    write("Downloading "..filename.."... ")
    if not DOWNLOADABLE_FILES[filename] then
      print("unknown file")
      return nil
    end

    local response, err = http.get(GITHUB_RAW_URL..filename)
    if not response then
      print("failed")
      print(tostring(err or "HTTP request failed"))
      return nil
    end

    local code = response.getResponseCode and response.getResponseCode()
    if code and (code < 200 or code >= 300) then
      response.close()
      print("failed (HTTP "..code..")")
      return nil
    end

    downloads[filename] = response.readAll()
    response.close()
    print("done")
  end
  return downloads
end

local function readStartupProgram()
  if not fs.exists(STARTUP_MANIFEST) then return nil end
  local handle = fs.open(STARTUP_MANIFEST, "r")
  if not handle then return nil end
  local filename = handle.readAll()
  handle.close()
  for _, program in ipairs(PROGRAM_FILES) do
    if program == filename then return filename end
  end
  return nil
end

local function promptStartupChoice()
  print("")
  print("Install selected program as:")
  print("1) startup.lua (run automatically at boot)")
  print("2) original filename only")
  write("Choice [2]: ")
  local choice = read():lower()
  return choice == "1" or choice == "y" or choice == "yes"
end

local function installFiles(downloads, startupProgram, createStartup)
  if createStartup and startupProgram and downloads[startupProgram] then
    downloads[STARTUP_FILE] = downloads[startupProgram]
  end

  local existing = {}
  for filename in pairs(downloads) do
    if fs.exists(filename) then existing[#existing + 1] = filename end
  end

  if #existing > 0 then
    print("The following files already exist:")
    for _, filename in ipairs(existing) do print("- "..filename) end
    write("Overwrite these program files? (y/N) ")
    if read():lower() ~= "y" then
      print("Installation cancelled; no files were changed.")
      return false
    end
  end

  for filename, contents in pairs(downloads) do
    local handle = fs.open(filename, "w")
    if not handle then
      print("Could not write "..filename..".")
      return false
    end
    handle.write(contents)
    handle.close()
  end

  if createStartup and startupProgram then
    local handle = fs.open(STARTUP_MANIFEST, "w")
    if not handle then
      print("Could not save startup program information.")
      return false
    end
    handle.write(startupProgram)
    handle.close()
  end
  return true
end

if not http then
  print("HTTP is disabled. Enable it in the CC:Tweaked server config.")
  return
end

local selected = promptPackage()
if not selected then return end

local files = {}
local startupProgram
local createStartup = false
if selected.updateInstaller then
  files = {"installer.lua"}
elseif selected.update then
  files = {"config_util.lua"}
  local foundProgram = false
  for _, filename in ipairs(PROGRAM_FILES) do
    if fs.exists(filename) then
      files[#files + 1] = filename
      foundProgram = true
    end
  end
  if fs.exists("installer.lua") then
    files[#files + 1] = "installer.lua"
    foundProgram = true
  end
  startupProgram = readStartupProgram()
  createStartup = startupProgram ~= nil
  if startupProgram and not fs.exists(startupProgram) then
    files[#files + 1] = startupProgram
    foundProgram = true
  end
  if not foundProgram then
    print("No installed DoorAuth programs found to update.")
    return
  end
else
  files = {"config_util.lua"}
  for _, filename in ipairs(selected.files) do
    files[#files + 1] = filename
  end
  startupProgram = selected.files[1]
  createStartup = promptStartupChoice()
end

print("")
local downloads = fetchFiles(files)
if not downloads then
  print("Download failed. No files were installed.")
  return
end

if installFiles(downloads, startupProgram, createStartup) then
  if startupProgram and createStartup then
    print("Installed "..startupProgram.." as "..STARTUP_FILE..".")
  elseif startupProgram then
    print("Installed "..startupProgram.." under its original filename.")
  else
    print("Update complete.")
  end
  print("Existing configuration data was not changed.")
end
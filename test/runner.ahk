; Simple test runner for TodoManager (AHK v2)
#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\JSON.ahk

LogPathErrors := A_ScriptDir "\\..\\errors.log"
LogPathDebug  := A_ScriptDir "\\..\\debug.log"

Log(msg) {
  FileAppend(Format("[{1}] TEST: {2}\r\n", A_Now, msg), A_ScriptDir "\\..\\debug.log")
}
Fail(msg) {
  FileAppend(Format("[{1}] TEST_FAIL: {2}\r\n", A_Now, msg), A_ScriptDir "\\..\\errors.log")
}

; 1) Clean start and run main script in TEST_MODE (no GUI)
dataFile := A_ScriptDir "\\..\\TodoManager.json"
try FileDelete(dataFile)

exe := "C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe"
if !FileExist(exe) {
  Fail("AutoHotkey v2 not found: " exe)
  ExitApp(1)
}

main := A_ScriptDir "\\..\\TodoManager.ahk"
if !FileExist(main) {
  Fail("TodoManager.ahk not found")
  ExitApp(1)
}

RunWait(Format('"{1}" "{2}" test', exe, main))

if !FileExist(dataFile) {
  Fail("TodoManager.json not created by SaveState")
  ExitApp(1)
}

; 2) Validate JSON structure and defaults
raw := FileRead(dataFile, "UTF-8")
data := JSON.parse(raw, false, true)
if !(data.Has("config") && data.Has("todos")) {
  Fail("JSON missing required keys: config/todos")
  ExitApp(1)
}

cfg := data["config"]
if (cfg["font_size"] < 8 || cfg["font_size"] > 28) {
  Fail("font_size out of bounds: " cfg["font_size"]) 
  ExitApp(1)
}
if (cfg["dim_percent"] < 0 || cfg["dim_percent"] > 90) {
  Fail("dim_percent out of bounds: " cfg["dim_percent"]) 
  ExitApp(1)
}

; 3) Tamper values and ensure clamping on next load
cfg["font_size"] := 100
cfg["dim_percent"] := 200
data["config"] := cfg
FileDelete(dataFile)
FileAppend(JSON.stringify(data), dataFile, "UTF-8")
RunWait(Format('"{1}" "{2}" test', exe, main))

raw2 := FileRead(dataFile, "UTF-8")
data2 := JSON.parse(raw2, false, true)
cfg2 := data2["config"]
if (cfg2["font_size"] > 28) {
  Fail("font_size not clamped: " cfg2["font_size"]) 
  ExitApp(1)
}
if (cfg2["dim_percent"] > 90) {
  Fail("dim_percent not clamped: " cfg2["dim_percent"]) 
  ExitApp(1)
}

Log("All tests passed.")
ExitApp(0)


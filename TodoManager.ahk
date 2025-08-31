#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off
#Include JSON.ahk

; TodoManager (AHK v2)
; - Shows only on Desktop
; - Borderless, draggable, resizable
; - ListView with toolbar, status bar
; - Settings (font size, dim percent)
; - JSON persistence

try DllCall("SetProcessDPIAware")

; --- Tray Menu ---
A_TrayMenu.Delete()
A_TrayMenu.Add("Exit", (*) => OnGuiClose())

; No Icon
;#NoTrayIcon

; ---------- Logging ----------
global LOG_ERRORS := A_ScriptDir "\\errors.log"
global LOG_DEBUG  := A_ScriptDir "\\debug.log"
try FileDelete(LOG_ERRORS)
try FileDelete(LOG_DEBUG)

LogDebug(msg) {
  FileAppend(Format("[{1}] DEBUG: {2}\r\n", A_Now, msg), LOG_DEBUG)
}
LogError(msg) {
  FileAppend(Format("[{1}] ERROR: {2}\r\n", A_Now, msg), LOG_ERRORS)
}
OnError(LogUnhandled)
LogUnhandled(e, mode) {
  LogError(Format("Unhandled: {1} at {2}:{3}", e.Message, e.File, e.Line))
  return false
}

; ---------- Config & Storage ----------
global DATA_PATH := A_ScriptDir "\\TodoManager.json"
; Set win_w/win_h to 0 so we can detect missing dims reliably
global config := Map("font_size", 12, "dim_percent", 50, "win_x", "", "win_y", "", "win_w", 0, "win_h", 0)
global todos := [] ; array of Map

LoadState()

LoadState() {
  global DATA_PATH, config, todos, firstRunNoDims

  try {
    loadedFromFile := false
    hasDims := false

    if FileExist(DATA_PATH) {
      loadedFromFile := true
      raw := FileRead(DATA_PATH, "UTF-8")

      if (Trim(raw) != "") {
        data := JSON.parse(raw, false, true)
        if data.Has("config") {
          cfg := data["config"]
          hasDims := cfg.Has("win_w") && cfg.Has("win_h") && (cfg["win_w"] + 0) > 0 && (cfg["win_h"] + 0) > 0
          for k, v in cfg
            config[k] := v
        }

        if data.Has("todos") {
          todos := data["todos"]
          ; Strip legacy reminder fields if present
          try {
            for t in todos {
              if t.Has("remind_at")
                t.Delete("remind_at")
              if t.Has("reminder_text")
                t.Delete("reminder_text")
            }
          } catch as e {
            LogError(Format("Sanitize reminders in LoadState: {1}", e.Message))
          }
        }
      }
    }

    firstRunNoDims := (!loadedFromFile) || (!hasDims)

    if (firstRunNoDims) {
      ; Preload sane first-run defaults (1000x700)
      config["win_w"] := 1000
      config["win_h"] := 700

      ; If no settings file exists at all, create it immediately with defaults
      if (!loadedFromFile) {
        try SaveState()
      }
    }

  } catch as e {
    LogError(Format("LoadState: {1}", e.Message))
  }
}

SaveState() {
  global DATA_PATH, config, todos
  try {

    data := Map("config", config, "todos", todos)
    jsonText := JSON.stringify(data)
    ; Delete existing file if present, but do not fail if missing
    try {
      if FileExist(DATA_PATH)
        FileDelete(DATA_PATH)
    } catch {
      ; ignore delete failures for non-existent file
    }
    FileAppend(jsonText, DATA_PATH, "UTF-8")

  } catch as e {
    LogError(Format("SaveState failed: {1} at {2}:{3} | Extra: {4}", e.Message, e.File, e.Line, e.Extra))
  }
}

; Ensure a settings file exists on first run (no file at all)
try {
  if (!FileExist(DATA_PATH)) {
    if ((config.Has("win_w") ? config["win_w"] + 0 : 0) <= 0)
      config["win_w"] := 1000
    if ((config.Has("win_h") ? config["win_h"] + 0 : 0) <= 0)
      config["win_h"] := 700
    SaveState()

  }
} catch as e {
  LogError(Format("Ensure settings file failed: {1}", e.Message))
}

; ---------- Globals / UI ----------
global mainGui, lv, sb, settingsBtn
global currentMon := 0, lastNonDesktopHwnd := 0
global toolbar := Map()
global toolbarTips := Map()
global icon_font := "Segoe MDL2 Assets"
global hovering := false

global edge_margin := 8
global isRestoring := true
; Fixed widths for non-title columns in ListView (priority merged into indicator)
global COL_W_IND := 50, COL_MIN_TITLE := 120
; Padding around the ListView control (not items)
global LV_PAD_X := 5
; Visual left padding after checkbox before the title text
global TITLE_LEFT_PAD := "  "

; Build GUI

GetDesktopWindowHandle() {
    ; Get the handle to the desktop shell window. This is generally more reliable.
    desktopHwnd := DllCall("GetShellWindow")
    
    ; If GetShellWindow fails for some reason, fall back to WinExist.
    if !desktopHwnd {
        desktopHwnd := WinExist("ahk_class WorkerW")
    }
    if !desktopHwnd {
        desktopHwnd := WinExist("ahk_class Progman", "Program Manager")
    }
    
    return desktopHwnd
}

desktopHwnd := GetDesktopWindowHandle()
if (!desktopHwnd) {
    LogError("Could not find desktop window handle for parenting the TodoManager GUI. Exiting.")
    ExitApp()
}

mainGui := Gui("+Parent" . desktopHwnd . " -Caption +AlwaysOnTop +Resize +ToolWindow")
mainGui.MarginX := 6
mainGui.MarginY := 6
mainGui.BackColor := "FFFFFF"

; Toolbar row
BuildToolbar()

; ListView (checkbox + todo first, indicator second; priority only in indicator)
lv := mainGui.Add("ListView", "x" . LV_PAD_X " y+5 w420 h400 Grid -Multi -Hdr Checked", ["Todo", ""]) ; header hidden, with checkboxes
lv.SetFont("s" config["font_size"] " q5", "Calibri") ; font size applies to list items
; Ensure checkbox style is applied (some environments require explicit Opt)
; Ensure checkbox style is applied
lv.Opt("+Checked")
lv.OnEvent("DoubleClick", (*) => EditSelected())
lv.OnEvent("Click", (*) => UpdateToolbarEnabled())
lv.OnEvent("ItemCheck", OnListItemCheck)

; Status bar
sb := mainGui.Add("StatusBar")
sb.SetFont("s10")
sb.SetText("Pending: 0 | Completed: 0 | Total: 0")

; Resize handling (persist size), ESC to hide
mainGui.OnEvent("Size", OnGuiSize)
mainGui.OnEvent("Close", OnGuiClose)
mainGui.OnEvent("Escape", (*) => mainGui.Hide())

; Borderless drag and resize
OnMessage(0x84, OnNcHitTest) ; WM_NCHITTEST
OnMessage(0x0232, OnExitSizeMove) ; WM_EXITSIZEMOVE
; Toolbar hover tooltips
OnMessage(0x200, OnAnyMouseMove) ; WM_MOUSEMOVE


OnMessage(0x0216, OnWmMoving) ; WM_MOVING
; Initial placement top-right based on preferred monitor
PlaceTopRight(PreferredMonitorIndex())
isRestoring := false
RefreshList()
UpdateToolbarEnabled()

OnExit(SaveOnExit)

; Timers

SetTimer(CheckHover, 200)
; (reminders removed)

; ---------- Toolbar ----------
BuildToolbar() {
  global mainGui, toolbar, icon_font, settingsBtn, toolbarTips

  makeTxt(code, tip, cb, color) {
    t := mainGui.Add("Text", "x+m yp w30 h28 Center 0x200 BackgroundTrans", Chr("0x" code))
    t.SetFont("s14 c" . color, icon_font)
    t.OnEvent("Click", cb)

    if tip {
      t.ToolTip := tip
      toolbarTips[t.Hwnd] := tip
    }
    return t
  }

  mainGui.Add("Text", "x6 y6 w1 h1")
  toolbar["add"]    := makeTxt("E710", "Add", (*) => AddTodo(),  "2E8B57")  ; green
  toolbar["edit"]   := makeTxt("E70F", "Edit", (*) => EditSelected(), "1E90FF") ; blue
  toolbar["prio"]   := makeTxt("E7C1", "Priority", (*) => SetPriority(), "FF8C00") ; orange
  ; Removed: complete button (handled via list checkboxes)
  toolbar["up"]     := makeTxt("E74A", "Move Up", (*) => MoveSelected(-1), "808080") ; gray
  toolbar["down"]   := makeTxt("E74B", "Move Down", (*) => MoveSelected(1),  "808080") ; gray
  toolbar["del"]    := makeTxt("E74D", "Delete", (*) => DeleteSelected(), "DC143C") ; crimson

  mainGui.Add("Text", "x+6 yp w100 h1")
  settingsBtn := mainGui.Add("Button", "yp w30 h28", Chr("0xE713"))
  settingsBtn.SetFont("s14", icon_font)
  settingsBtn.ToolTip := "Settings"
  settingsBtn.OnEvent("Click", (*) => OpenSettings())
  toolbarTips[settingsBtn.Hwnd] := "Settings"
}

global lastTipHwnd := 0
OnAnyMouseMove(wParam, lParam, msg, hwnd) {
  global mainGui, toolbarTips, lastTipHwnd

  try {
    MouseGetPos(, , &wID, &cID, 2)

    if (wID != mainGui.Hwnd) {
      if (lastTipHwnd) {
        ToolTip("")
        lastTipHwnd := 0
      }
      return
    }

    if (cID && toolbarTips.Has(cID)) {
      if (lastTipHwnd != cID) {
        ToolTip(toolbarTips[cID])
        lastTipHwnd := cID
      }
    } else if (lastTipHwnd) {
      ToolTip("")
      lastTipHwnd := 0
    }
  } catch {
  }
}

UpdateToolbarEnabled() {
  global toolbar, lv
  hasSel := lv.GetNext() > 0
  ; Emulate enabled/disabled by color dimming for text controls
  setColor(ctrl, hex) => ctrl.SetFont("s14 c" . hex, icon_font)
  setColor(toolbar["add"],  "2E8B57")
  setColor(toolbar["edit"], hasSel ? "1E90FF" : "C0C0C0")
  setColor(toolbar["prio"], hasSel ? "FF8C00" : "C0C0C0")
  setColor(toolbar["up"],   hasSel ? "808080" : "C0C0C0")
  setColor(toolbar["down"], hasSel ? "808080" : "C0C0C0")
  setColor(toolbar["del"],  hasSel ? "DC143C" : "C0C0C0")
}



; ---------- Dimming / Hover ----------
ApplyDim(dim := true) {
  global mainGui, config

  try {
    alpha := dim ? Round(255 * (100 - config["dim_percent"]) / 100) : 255
    WinSetTransparent(alpha, mainGui.Hwnd)
  } catch as e {
    LogError(Format("ApplyDim: {1}", e.Message))
  }
}

IsMouseOverGui() {
  global mainGui

  try {
    MouseGetPos(&mx, &my) ; Get mouse coordinates
    WinGetPos(&wx, &wy, &ww, &wh, mainGui.Hwnd) ; Get GUI position and size

    ; Check if mouse coordinates are within GUI bounds
    return (mx >= wx && mx < (wx + ww) && my >= wy && my < (wy + wh))
  } catch {
    return false
  }
}

CheckHover() {
  global hovering, mainGui

  over := IsMouseOverGui()
  focused := WinActive("A") = mainGui.Hwnd

  if (over) && !hovering {
    hovering := true
    ApplyDim(false)
  } else if !(over) && hovering {
    hovering := false
    ApplyDim(true)
  }
}

; ---------- Borderless drag/resize ----------
OnNcHitTest(wParam, lParam, msg, hwnd) {
  global mainGui, edge_margin

  if hwnd != mainGui.Hwnd
    return

  try {
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    WinGetPos(&wx, &wy, &ww, &wh, hwnd)
    left   := wx, right := wx + ww, top := wy, bottom := wy + wh
    onLeft   := x >= left  && x < left + edge_margin
    onRight  := x <= right && x > right - edge_margin
    onTop    := y >= top   && y < top + edge_margin
    onBottom := y <= bottom && y > bottom - edge_margin

    if onTop && onLeft
      return 13 ; HTTOPLEFT
    if onTop && onRight
      return 14 ; HTTOPRIGHT
    if onBottom && onLeft
      return 16 ; HTBOTTOMLEFT
    if onBottom && onRight
      return 17 ; HTBOTTOMRIGHT
    if onTop
      return 12 ; HTTOP
    if onBottom
      return 15 ; HTBOTTOM
    if onLeft
      return 10 ; HTLEFT
    if onRight
      return 11 ; HTRIGHT
    return 2 ; HTCAPTION (drag anywhere else)
  } catch as e {
    LogError(Format("OnNcHitTest: {1}", e.Message))
  }
}

OnExitSizeMove(*) {
  ; Do not persist on drag finish; we save on app exit
  return
}


OnGuiSize(guiObj, minMax, width, height) {
  try {
    if width < 260
      width := 260
  if height < 200
      height := 200
  settingsBtn.Move(width - 36)
    lv.GetPos(&lx, &ly)
    newH := (height - 24) - ly
    if (newH < 0)
      newH := 0
    lv.Move(, , width - (2 * LV_PAD_X), newH)
  AdjustListColumnsFromWidth(width)
  sb.Move(, height - 24, width, 24)
  ; save only on exit
  } catch as e {
    LogError(Format("OnGuiSize: {1}", e.Message))
  }
}

AdjustListColumnsFromWidth(totalW) {
  global lv, COL_W_IND, COL_MIN_TITLE

  try {
    listW := totalW - (2 * LV_PAD_X)
    fixed := COL_W_IND + 20 ; padding for scrollbar/margins
    titleW := listW - fixed

    if (titleW < COL_MIN_TITLE)
      titleW := COL_MIN_TITLE
    ; Right-align indicator text and set fixed width
    lv.ModifyCol(2, "Right")
    lv.ModifyCol(2, COL_W_IND)
    lv.ModifyCol(1, titleW)
  } catch as e {
    LogError(Format("AdjustListColumnsFromWidth: {1}", e.Message))
  }
}

PlaceTopRight(mon := 0) {
  global mainGui, config

  try {
    ; Resolve monitor to use
    if (mon <= 0) {
      mon := ActiveMonitorIndex()
    }

    MonitorGetWorkArea(mon, &L2, &T2, &R2, &B2)

    ; Use persisted window box only if not first run with no dims
    if (!firstRunNoDims && (config["win_w"] + 0) > 0 && (config["win_h"] + 0) > 0) {
      rx := config["win_x"], ry := config["win_y"], rw := config["win_w"], rh := config["win_h"]


      minW := 260, minH := 180
      maxW := (R2 - L2) - 20
      maxH := (B2 - T2) - 40

      if (rw = "" || rw < minW)
        rw := minW
      if (rh = "" || rh < minH)
        rh := minH
      if (rw > maxW)
        rw := maxW
      if (rh > maxH)
        rh := maxH

      if (rx = "")
        rx := R2 - rw
      if (ry = "")
        ry := T2

      rx := Min(Max(rx, L2), R2 - rw)
      ry := Min(Max(ry, T2), B2 - rh)

      mainGui.Show(Format("x{1} y{2} w{3} h{4} NoActivate", rx, ry, rw, rh))
      WinMove(rx, ry, rw, rh, mainGui.Hwnd)
      ApplyDim(true)
      WinGetPos(&arx, &ary, &arw, &arh, mainGui.Hwnd)

      ; Update in-memory only; persistence happens on user move/resize
      config["win_x"] := arx, config["win_y"] := ary, config["win_w"] := arw, config["win_h"] := arh
      return
    }

    ; First-run placement: top-right of selected monitor with sane defaults
    w := config["win_w"] + 0, h := config["win_h"] + 0
    if (w < 1000)
      w := 1000
    if (h < 700)
      h := 700
    x := R2 - w, y := T2

    mainGui.Show(Format("x{1} y{2} w{3} h{4} NoActivate Hide", x, y, w, h))
    Sleep 50
    WinMove(x, y, w, h, mainGui.Hwnd)
    ApplyDim(true)

    ; Persist once so next run restores these
    config["win_x"] := x, config["win_y"] := y, config["win_w"] := w, config["win_h"] := h
    try SaveState()
  } catch as e {
    LogError(Format("PlaceTopRight: {1}", e.Message))
  }
}

ActiveMonitorIndex() {
  ; Returns monitor index for mouse pointer; falls back to primary
  try {
    MouseGetPos(&mx, &my)
    cnt := MonitorGetCount()
    idx := 0
    Loop cnt {
      i := A_Index
      MonitorGet(i, &l, &t, &r, &b)
      if (mx >= l && mx < r && my >= t && my < b) {
        idx := i
        break
      }
    }
    if (idx)
      return idx
    ; Fallback: primary monitor
    return MonitorGetPrimary()
  } catch {
    return 1
  }
}

PreferredMonitorIndex() {
  global lastNonDesktopHwnd
  try {
    if (lastNonDesktopHwnd) {
      if WinExist("ahk_id " lastNonDesktopHwnd) {
        return MonitorIndexFromWindow(lastNonDesktopHwnd)
      }
    }
  } catch {
  }
  return ActiveMonitorIndex()
}

MonitorIndexFromWindow(hwnd) {
  try {
    WinGetPos(&x, &y, &w, &h, hwnd)
    cx := x + w//2, cy := y + h//2
    cnt := MonitorGetCount()
    best := 0
    Loop cnt {
      i := A_Index
      MonitorGet(i, &l, &t, &r, &b)
      if (cx >= l && cx < r && cy >= t && cy < b) {
        best := i
        break
      }
    }
    return best ? best : MonitorGetPrimary()
  } catch {
    return MonitorGetPrimary()
  }
}

SaveWindowRect() {
  global mainGui, config
  try {
    WinGetPos(&x, &y, &w, &h, mainGui.Hwnd)
    if (w <= 0 || h <= 0)
      return
    config["win_x"] := x, config["win_y"] := y, config["win_w"] := w, config["win_h"] := h

    SaveState()
  } catch as e {
    LogError(Format("SaveWindowRect: {1}", e.Message))
  }
}

; ---------- Todo List ----------
RefreshList() {
  global lv, todos

  try {
    lv.Opt("-Redraw")
    lv.Delete()

  for idx, t in todos {
      pri := t.Has("priority") ? t["priority"] : "default"
      ind := (pri = "critical") ? "⛔" : (pri = "high") ? "⚠" : ""

      if (t.Has("comments")) {
        c := Trim(t["comments"])
        if (c != "")
          ind := ind != "" ? ind . " 📝" : "📝"
      }

      ; Completed icon removed; completion is indicated via checkbox and strikethrough
      if (t.Has("completed") && t["completed"]) {
        ind := ind != "" ? "✅ " . ind : "✅"
      }

      title := t["title"]

      ; Strip leading completed icon from indicator if present (checkboxes now handle completion)
      if (t.Has("completed") && t["completed"]) {
        try {
          sp := InStr(ind, " ")
          if (sp > 0)
            ind := SubStr(ind, sp + 1)
          else
            ind := ""
        } catch as e {
          LogError(Format("Strip completed icon: {1}", e.Message))
        }
      }

      if t.Has("completed") && t["completed"]
        title := StrikeText(title)
      displayTitle := TITLE_LEFT_PAD . title
      opts := (t.Has("completed") && t["completed"]) ? "Check" : ""
      lv.Add(opts, displayTitle, ind)
    }


    lv.Opt("+Redraw")
    UpdateCounts()
    lv.Modify(0, "-Select")
  } catch as e {
    LogError(Format("RefreshList: {1}", e.Message))
  }
}

UpdateCounts() {
  global sb, todos
  try {
    total := todos.Length
    comp := 0
    for t in todos
      if t.Has("completed") && t["completed"]
        comp++
    pend := total - comp
    sb.SetText(Format("Pending: {1} | Completed: {2} | Total: {3}", pend, comp, total))
  } catch as e {
    LogError(Format("UpdateCounts: {1}", e.Message))
  }
}

SelectedIndex() {
  global lv
  return lv.GetNext()
}

; Handle checkbox toggles for completion
OnListItemCheck(ctrl, row, checked) {
  global todos
  try {
    idx := row + 0
    if (idx <= 0 || idx > todos.Length)
      return
    curr := todos[idx]
    newDone := (checked ? true : false)
    oldDone := curr.Has("completed") && curr["completed"]
    if (newDone = oldDone)
      return
    curr["completed"] := newDone
    if (newDone) {
      ; push completed to bottom
      t := todos.RemoveAt(idx)
      todos.Push(t)
    }
    SaveState()
    RefreshList()
  } catch as e {
    LogError(Format("OnListItemCheck: {1}", e.Message))
  }
}

AddTodo() {
  global todos
  try {
    dlg := OpenTodoDialog("add", "", "")
    if !dlg["ok"]
      return
    text := Trim(dlg["title"])
    item := Map("id", A_TickCount, "title", text, "priority", "default", "completed", false, "created_at", A_Now)
    if (dlg.Has("comments")) {
      c := Trim(dlg["comments"])
      if (c != "")
        item["comments"] := c
    }
    todos.InsertAt(1, item)
    SaveState()
    RefreshList()

  } catch as e {
    LogError(Format("AddTodo: {1}", e.Message))
  }
}

EditSelected() {
  global todos
  idx := SelectedIndex()
  if idx <= 0
    return
  try {
    cur := todos[idx]
    dlg := OpenTodoDialog("edit", cur["title"], cur.Has("comments") ? cur["comments"] : "")
    if !dlg["ok"]
      return
    text := Trim(dlg["title"])
    cur["title"] := text
    if (dlg.Has("comments")) {
      c := Trim(dlg["comments"])
      if (c = "") {
        if cur.Has("comments")
          cur.Delete("comments")
      } else {
        cur["comments"] := c
      }
    }
    SaveState()
    RefreshList()
  } catch as e {
    LogError(Format("EditSelected: {1}", e.Message))
  }
}

; ---------- Add/Edit Dialog ----------
OpenTodoDialog(mode := "add", initialTitle := "", initialComments := "") {
  global mainGui
  try {
    g := Gui("+Owner" mainGui.Hwnd " -MinimizeBox -MaximizeBox")
    g.MarginX := 14, g.MarginY := 14
    g.BackColor := "FFFFFF"

    titleText := mode = "add" ? "Add Todo" : "Edit Todo"
    g.Title := titleText

    ; Header
    hdr := g.Add("Text", "xm ym w420 0x200", titleText)
    hdr.SetFont("s12 c333333")

    ; Subtitle
    sub := g.Add("Text", "xm y+m w420 c666666", "Keep it short and clear.")
    sub.SetFont("s9")

    ; Title input
    g.Add("Text", "xm y+m c333333", "Title:")
    ; Single-line input for concise todos
    eTitle := g.Add("Edit", "xm w420", initialTitle)
    eTitle.SetFont("s11")

    ; Live char count
    cnt := g.Add("Text", "xm y+4 c999999", "0 characters")
    ; Inline validation message (hidden by default)
    lblErr := g.Add("Text", "xm y+2 cFF3B30 Hidden", "Title cannot be empty.")

    ; Comments (optional)
    g.Add("Text", "xm y+m c333333", "Comments (optional):")
    eComments := g.Add("Edit", "xm w420 r10", initialComments)
    eComments.SetFont("s10")

    ; Buttons row
    btnSaveText := mode = "add" ? "Add" : "Save"
    btnSave := g.Add("Button", "xm y+m w100 h28 Default", btnSaveText)
    btnCancel := g.Add("Button", "x+m w100 h28", "Cancel")

    ; Live validation + counter updater
    UpdateUI(*) {
      try {
        len := StrLen(Trim(eTitle.Text))
        cnt.Text := Format("{1} characters", len)
        if (len > 0) {
          if lblErr.Visible
            lblErr.Visible := false
          btnSave.Enabled := true
        } else {
          if !lblErr.Visible
            lblErr.Visible := true
          btnSave.Enabled := false
        }
      } catch {
      }
    }
    eTitle.OnEvent("Change", UpdateUI)

    ; Keyboard handling
    g.OnEvent("Escape", (*) => g.Destroy())

    result := Map("ok", false, "title", initialTitle, "comments", initialComments)
    btnSave.OnEvent("Click", (*) => (
      (StrLen(Trim(eTitle.Text)) = 0)
        ? (lblErr.Visible := true, eTitle.Focus())
        : (result["ok"] := true, result["title"] := Trim(eTitle.Text), result["comments"] := Trim(eComments.Text), g.Destroy())
    ))
    btnCancel.OnEvent("Click", (*) => g.Destroy())

    ; Size and show
    g.Show("AutoSize w460")
    eTitle.Focus()
    ; Initialize UI state after showing to ensure correct layout
    SetTimer(UpdateUI, -10)
    WinWaitClose("ahk_id " g.Hwnd)

    return result
  } catch as e {
    LogError(Format("OpenTodoDialog: {1}", e.Message))
    return Map("ok", false, "title", initialTitle, "comments", initialComments)
  }
}

SetPriority() {
  global todos
  idx := SelectedIndex()
  if idx <= 0
    return
  m := Menu()
  m.Add("None", (*) => ApplyPrio("default"))
  m.Add("High", (*) => ApplyPrio("high"))
  m.Add("Critical", (*) => ApplyPrio("critical"))
  m.Show()
}

ApplyPrio(p) {
  global todos
  idx := SelectedIndex()
  if idx <= 0
    return
  try {
    todos[idx]["priority"] := p
    SaveState()
    RefreshList()
  } catch as e {
    LogError(Format("ApplyPrio: {1}", e.Message))
  }
}

; Removed: CompleteSelected() — replaced by OnListItemCheck via list checkboxes

MoveSelected(dir) {
  global todos
  idx := SelectedIndex()
  if idx <= 0
    return
  try {
    newIdx := idx + dir
    if newIdx < 1 || newIdx > todos.Length
      return
    tmp := todos[idx]
    todos[idx] := todos[newIdx]
    todos[newIdx] := tmp
    SaveState()
    RefreshList()
    lv.Modify(newIdx, "Select Vis Focus")
  } catch as e {
    LogError(Format("MoveSelected: {1}", e.Message))
  }
}

DeleteSelected() {
  global todos
  idx := SelectedIndex()
  if idx <= 0
    return
  try {
    if MsgBox("Delete selected todo?", "Confirm", 0x4) = "Yes" {
      todos.RemoveAt(idx)
      SaveState()
      RefreshList()
    }
  } catch as e {
    LogError(Format("DeleteSelected: {1}", e.Message))
  }
}

; ---------- Settings ----------
OpenSettings() {
  global config, lv, mainGui
  try {
    g := Gui("+Owner" mainGui.Hwnd " -MinimizeBox -MaximizeBox")
    g.MarginX := 12, g.MarginY := 12
    g.Add("Text", , "Font Size (8-28):")
  ; Numeric-only with UpDown spinner and range clamp
    eSize := g.Add("Edit", "w220 Number", config["font_size"])
  g.Add("UpDown", "Range8-28", config["font_size"]) ; allowed font size range
  hintFs := g.Add("Text", "xm y+2 c999999", "Allowed: 8–28")
  hintFs.SetFont("s9")
    g.Add("Text", "xm y+m", "Dim Percentage (0-90):")
    eDim := g.Add("Edit", "w220 Number", config["dim_percent"])
  g.Add("UpDown", "Range0-90", config["dim_percent"]) ; allowed dim range
  hintDim := g.Add("Text", "xm y+2 c999999", "Allowed: 0–90")
  hintDim.SetFont("s9")
    ok := g.Add("Button", "xm y+m w104 Default", "Save")
    cancel := g.Add("Button", "x+m w104", "Cancel")
    okPressed := false, newFs := config["font_size"], newDp := config["dim_percent"]
    ok.OnEvent("Click", (*) => (okPressed := true, newFs := eSize.Text, newDp := eDim.Text, g.Destroy()))
    cancel.OnEvent("Click", (*) => g.Destroy())
    g.Title := "Settings"
    dlgW := 300
    g.Show("AutoSize w" dlgW)
    WinWaitClose("ahk_id " g.Hwnd)
    fs := (newFs + 0)
    dp := (newDp + 0)
    if fs >= 8 && fs <= 28
      config["font_size"] := fs
    if dp >= 0 && dp <= 90
      config["dim_percent"] := dp
    lv.SetFont("s" config["font_size"])
    SaveState()
    ApplyDim(!IsMouseOverGui())
  } catch as e {
    LogError(Format("OpenSettings: {1}", e.Message))
  }
}

; ---------- Text helpers ----------
StrikeText(s) {
  out := ""
  for c in StrSplit(s, "")
    out .= c . Chr(0x0336)
  return out
}

; ---------- Edge Snapping ----------
GetWorkAreaForRect(left, top, right, bottom, &L, &T, &R, &B) {
  cx := left + (right - left) // 2
  cy := top + (bottom - top) // 2
  cnt := MonitorGetCount()
  Loop cnt {
    i := A_Index
    MonitorGetWorkArea(i, &l2, &t2, &r2, &b2)
    if (cx >= l2 && cx < r2 && cy >= t2 && cy < b2) {
      L := l2, T := t2, R := r2, B := b2
      return
    }
  }
  MonitorGetWorkArea(, &L, &T, &R, &B)
}

OnWmMoving(wParam, lParam, msg, hwnd) {
  global mainGui
  SNAP_DIST := 16
  try {
    if (hwnd != mainGui.Hwnd)
      return
    left   := NumGet(lParam, 0,  "Int")
    top    := NumGet(lParam, 4,  "Int")
    right  := NumGet(lParam, 8,  "Int")
    bottom := NumGet(lParam, 12, "Int")
    w := right - left, h := bottom - top
    GetWorkAreaForRect(left, top, right, bottom, &L, &T, &R, &B)
    if (Abs(left - L) <= SNAP_DIST)
      left := L
    else if (Abs((left + w) - R) <= SNAP_DIST)
      left := R - w
    if (Abs(top - T) <= SNAP_DIST)
      top := T
    else if (Abs((top + h) - B) <= SNAP_DIST)
      top := B - h
    right := left + w, bottom := top + h
    NumPut("Int", left,  lParam, 0)
    NumPut("Int", top,   lParam, 4)
    NumPut("Int", right, lParam, 8)
    NumPut("Int", bottom,lParam, 12)
    return true
  } catch as e {
  }
}

OnGuiClose(*) {
  try {
    SaveWindowRect()
  } catch as e {
  }
  ExitApp()
}

SaveOnExit(ExitReason, ExitCode) {
  try {
    SaveWindowRect()
  } catch as e {
    LogError(Format("OnExit save failed: {1}", e.Message))
  }
}

#Requires AutoHotkey v1.1
#Persistent
;Force (rather than Ignore) so the elevated re-launch can replace the original instance.
#SingleInstance Force

#Include %A_ScriptDir%\Ini.ahk
#Include %A_ScriptDir%\Settings.ahk

FileInstall, unlocked.ico, %A_ScriptDir%\unlocked.ico, 0
FileInstall, locked.ico, %A_ScriptDir%\locked.ico, 0

settings := new Settings()

;Touchpad locking uses Disable-PnpDevice, which requires administrator rights.
;If the feature is enabled but the script is not elevated, relaunch it elevated.
touchpadFeatureEnabled := settings.LockTouchpad()
if (touchpadFeatureEnabled && !A_IsAdmin)
{
    if (A_IsCompiled)
        Run *RunAs "%A_ScriptFullPath%",, UseErrorLevel
    else
        Run *RunAs "%A_AhkPath%" "%A_ScriptFullPath%",, UseErrorLevel

    if (ErrorLevel) {
        touchpadFeatureEnabled := false
        MsgBox, 48, Keyboard Locker, Touchpad locking requires administrator privileges.`nThe script will continue, but only the keyboard will be locked.
    } else {
        ExitApp
    }
}

;Tracks whether this script disabled the touchpad, so we only re-enable what we disabled.
touchpadLockedByUs := false
touchpadActiveId := ""
touchpadLockVerifyTries := 0
touchpadUnlockVerifyTries := 0
pendingExitAfterUnlock := false

;Never leave the touchpad disabled when the script exits.
;NOTE: in AutoHotkey v1 the OnExit target must be a label/subroutine, not a function.
OnExit, CleanupOnExitLabel

;Remove leftover helper scripts from an earlier run.
FileDelete, %A_Temp%\keyboard-locker-pnp-*.ps1
FileDelete, %A_Temp%\keyboard-locker-detect-touchpad.ps1
FileDelete, %A_Temp%\keyboard-locker-touchpad.tsv

;Identify the touchpad up front (no keyboard hook is installed yet, so this cannot delay input).
if (touchpadFeatureEnabled)
{
    if (settings.TouchpadInstanceId() = "")
    {
        detectedId := DetectTouchpadDeviceId()
        if (detectedId != "")
            settings.SetTouchpadInstanceId(detectedId)
    }
}

;(DO NOT CHANGE) tracks whether or not the keyboard is currently locked
locked := false

;create the tray icon and do initial setup
initialize()

;set up the keyboard shortcut to lock the keyboard
Hotkey, % settings.Shortcut(), ShortcutTriggered

;end execution here - the rest of the file is functions and callbacks
return

initialize()
{
	global touchpadFeatureEnabled

	;initialize the tray icon and menu
	Menu, Tray, Icon, %A_ScriptDir%\unlocked.ico
	Menu, Tray, NoStandard
	Menu, Tray, Tip, % "Press " . settings.ShortcutHint() . " to lock your keyboard"
	Menu, Tray, Add, Lock keyboard, ToggleKeyboard
	if (touchpadFeatureEnabled)
		Menu, Tray, Add, Enable touchpad now, ManualEnableTouchpad
	Menu, Tray, Click, 1
	Menu, Tray, Default, Lock keyboard
	if (settings.HideTooltips()) {
		Menu, Tray, add, Show tray notifications, ToggleTray
	} else {
		Menu, Tray, add, Hide tray notifications, ToggleTray
	}
	Menu, Tray, Add, Exit, Exit

	if (settings.LockOnOpen()) {
		LockKeyboard(true)
	} else if (!settings.HideTooltips()) {
		TrayTip,,% "Press " . settings.ShortcutHint() . " to lock your keyboard",10,1
	}
}

;callback for when the keyboard shortcut is pressed
ShortcutTriggered:
    ;check if shortcut is disabled in settings
    if (settings.DisableShortcut())
    {
        return
    }

    ;if we're already locked, stop here
    if (locked)
    {
        return
    }

	;wait for each shortcut key to be released, so they don't get "stuck"
	for index, key in StrSplit(settings.ShortcutHint(), "+")
	{
		KeyWait, %key%
    }

	LockKeyboard(true)
return


;"Lock/Unlock keyboard" menu clicked
ToggleKeyboard()
{
	global locked

	if (locked) {
		LockKeyboard(false)
	} else {
		LockKeyboard(true)
	}
}

;"Hide/Show tray notifications" menu clicked
ToggleTray()
{
	if (settings.HideTooltips()) {
	    settings.SetHideTooltips(false)
		Menu, Tray, Rename, Show tray notifications, Hide tray notifications
	} else {
	    settings.SetHideTooltips(true)
		Menu, Tray, Rename, Hide tray notifications, Show tray notifications
	}
}

;"Exit" menu clicked
Exit()
{
	ExitApp
}

;Lock or unlock the keyboard
LockKeyboard(lock)
{
	global locked, touchpadFeatureEnabled, touchpadLockedByUs, pendingExitAfterUnlock

	;handle pointing to the keyboard hook
	static hHook = 0

	;lock status already matches what we were asked to do, no action necessary
	if ((hHook != 0) = lock) {
		return
	}
 
	if (lock) {
	    ;check that we didn't leave ourselves without a way to unlock again
	    if(settings.DisablePassword() && settings.LockMouse())
	    {
	        MsgBox, You have disabled password unlocking and enabled mouse locking, which will prevent you from unlocking your system. Please re-enable one or the other.
	        return
	    }

	    ;change the tray icon to a lock
		Menu, Tray, Icon, %A_ScriptDir%\locked.ico

        ;hint at the unlock password
		Menu, Tray, Tip, % "Type """ . settings.Password() . """ to unlock your keyboard"

        ;update menu to unlock
		Menu, Tray, Rename, Lock keyboard, Unlock keyboard

        ;lock the keyboard
		hHook := DllCall("SetWindowsHookEx", "Ptr", WH_KEYBOARD_LL:=13, "Ptr", RegisterCallback("Hook_Keyboard","Fast"), "Uint", DllCall("GetModuleHandle", "Uint", 0, "Ptr"), "Uint", 0, "Ptr")
		locked := true

		;also lock the built-in touchpad (external mice keep working)
		;deferred: the keyboard hook must keep being serviced while this runs
		if (touchpadFeatureEnabled) {
			SetTimer, LockTouchpadTimer, -10
		}

		;also lock the mouse, if configured to do so
		if (settings.LockMouse()) {
			Hotkey, LButton, doNothing
			Hotkey, RButton, doNothing
			Hotkey, MButton, doNothing
			BlockInput, MouseMove
		}

        ;remind user what the password is
		if (!settings.HideTooltips()) {
			tip := "Your keyboard is now locked.`nType """ . settings.Password() . """ to unlock it."
			if (touchpadFeatureEnabled)
				tip .= "`nThe built-in touchpad is locked too; external mice still work."
			TrayTip,,%tip%,10,1
		}
	} else {
        ;unlock the keyboard
		DllCall("UnhookWindowsHookEx", "Ptr", hHook)
		hHook := 0
		locked := false

        ;also unlock the mouse, if configured to do so
        if (settings.LockMouse()) {
            Hotkey, LButton, Off
            Hotkey, MButton, Off
            Hotkey, RButton, Off
            BlockInput, MouseMoveOff
        }

		;re-enable the touchpad if this script disabled it
		;deferred: when called from Hook_Keyboard, the keyboard hook must return quickly
		touchpadUnlockScheduled := false
		if (touchpadLockedByUs) {
			SetTimer, EnableTouchpadTimer, -10
			touchpadUnlockScheduled := true
		}

	    ;change tray icon back to unlocked
		Menu, Tray, Icon, %A_ScriptDir%\unlocked.ico

        ;hint at the keyboard shortcut to lock again
		Menu, Tray, Tip, % "Press " . settings.ShortcutHint() . " to lock your keyboard"

        ;update menu to lock
		Menu, Tray, Rename, Unlock keyboard, Lock keyboard

        ;remind user what the keyboard shortcut to lock is
		if (!settings.HideTooltips()) {
			TrayTip,,% "Your keyboard is now unlocked.`nPress " . settings.ShortcutHint() . " to lock it again.",10,1
		}

		if(settings.CloseOnUnlock())
		{
			if (touchpadUnlockScheduled) {
				;let the deferred touchpad re-enable run first (it spawns PowerShell,
				;which keeps running after this process exits)
				pendingExitAfterUnlock := true
			} else {
			    ExitApp
			}
		}
	}
}

;Catch and discard keypresses when the keyboard is locked, and monitor for password inputs
Hook_Keyboard(nCode, wParam, lParam)
{
    ;track our position while correctly typing the password
	static count = 0

    ;is this a keyUp event (or keyDown)
    isKeyUp := NumGet(lParam+0, 8, "UInt") & 0x80

    ;get the scan code of the key pressed/released
    gotScanCode := NumGet(lParam+0, 4, "UInt")

    ;track the left/right shift keys, to handle capitals and symbols in passwords, because getkeystate calls don't work with our method of locking the keyboard
    ;if you can figure out how to use a getkeystate call to check for shift, or you have a better way to handle upper case letters and symbols, let me know
	static shifted = 0
    if(gotScanCode = 0x2A || gotScanCode = 0x36) {
        if(isKeyUp) {
            shifted := 0
        } else {
            shifted := 1
        }
        return 1
    }

	;check password progress/completion
	if (!settings.DisablePassword() && !isKeyUp) {
	    expectedCharacter := SubStr(settings.Password(), count+1, 1)
        expectedScanCode := GetKeySC(expectedCharacter)
        requiresShift := requiresShift(expectedCharacter)

        ;did they type the correct next password letter?
	    if(expectedScanCode == gotScanCode && requiresShift == shifted) {
	        count := count + 1

	        ;password is complete!
	        if(count == StrLen(settings.Password())) {
                count = 0
                shifted = 0
                LockKeyboard(false)
            }
	    } else {
			count = 0
        }
    }

	return 1
}

;Determine if this character requires shift to be pressed (capital letter or symbol)
requiresShift(chr)
{
    ;upper case characters always require shift
    if(isUpperCase(chr)) {
        return true
    }

    ;symbols that require shift
    static symbols = ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", """", "<", ">", "?"]
    if(inArray(chr, symbols)) {
        return true
    }

    ;anything else is false
    return false
}

;Is the string (or character) upper case
isUpperCase(str)
{
    if str is upper
        return true
    else
        return false
}

;Is the string (or character) lower case
isLowerCase(str)
{
    if str is lower
        return true
    else
        return false
}

;Check if the haystack array contains the needle
inArray(needle, haystack) {
    ;only accept objects and arrays
	if(!IsObject(haystack) || haystack.Length() == 0) {
	    return false
	}

	for index, value in haystack {
		if (value == needle) {
		    return index
		}
    }
	return false
}

;---------------------------------------------------------------------------
; Touchpad locking
; The built-in touchpad is disabled/enabled via PowerShell's PnP cmdlets.
; External mice are never touched; the keyboard hook is unaffected.
;---------------------------------------------------------------------------

;"Enable touchpad now" tray menu item
ManualEnableTouchpad:
	id := settings.TouchpadInstanceId()
	if (id = "") {
		MsgBox, 48, Keyboard Locker, The touchpad has not been identified yet.`nSet touchpad-instance-id in settings.ini.
		return
	}
	EnableTouchpadInBackground(id)
	if (!settings.HideTooltips())
		TrayTip,, Enabling the touchpad...,10,1
return

;runs shortly after the keyboard is locked (keeps the hook serviced)
LockTouchpadTimer:
	if (locked)
		LockTouchpad()
return

;runs after the keyboard is unlocked
EnableTouchpadTimer:
	if (!locked) {
		id := touchpadActiveId
		if (id = "")
			id := settings.TouchpadInstanceId()
		if (id != "")
			EnableTouchpadInBackground(id)
	}
	if (pendingExitAfterUnlock) {
		pendingExitAfterUnlock := false
		;the spawned enable command keeps running after this process exits; don't
		;spawn a second one from OnExit
		touchpadLockedByUs := false
		ExitApp
	}
return

;verify that the touchpad actually got disabled (the command runs in the background)
VerifyTouchpadLockTimer:
	if (!locked || !touchpadLockedByUs || touchpadActiveId = "")
		return
	if (IsDeviceDisabled(touchpadActiveId))
		return
	touchpadLockVerifyTries += 1
	if (touchpadLockVerifyTries < 3) {
		RunPnpCommand(touchpadActiveId, false)
		SetTimer, VerifyTouchpadLockTimer, -1500
		return
	}
	touchpadLockVerifyTries := 0
	touchpadLockedByUs := false
	NotifyTouchpad("The touchpad could not be disabled.`nSee touchpad-error.log for details.")
return

;verify that the touchpad actually got re-enabled
VerifyTouchpadUnlockTimer:
	if (locked || touchpadActiveId = "")
		return
	if (!IsDeviceDisabled(touchpadActiveId)) {
		touchpadUnlockVerifyTries := 0
		touchpadLockedByUs := false
		return
	}
	touchpadUnlockVerifyTries += 1
	if (touchpadUnlockVerifyTries < 4) {
		RunPnpCommand(touchpadActiveId, true)
		SetTimer, VerifyTouchpadUnlockTimer, -1500
		return
	}
	touchpadUnlockVerifyTries := 0
	touchpadLockedByUs := false
	NotifyTouchpad("The touchpad could not be re-enabled.`nUse the tray menu or Device Manager.")
return

;disable the built-in touchpad; called from LockTouchpadTimer
LockTouchpad()
{
	global settings, touchpadLockedByUs, touchpadActiveId, touchpadLockVerifyTries

	id := settings.TouchpadInstanceId()
	if (id = "") {
		NotifyTouchpad("Could not identify the built-in touchpad.`nSet touchpad-instance-id in settings.ini.")
		return
	}

	errorCode := GetDeviceErrorCode(id)
	if (errorCode = -1) {
		NotifyTouchpad("The configured touchpad device was not found.`nCheck touchpad-instance-id in settings.ini.")
		return
	}

	;already disabled: if we disabled it earlier we still own it (so unlock re-enables it);
	;if it was disabled by someone else, leave it alone
	if (errorCode = 22)
		return

	if (RunPnpCommand(id, false)) {
		touchpadLockedByUs := true
		touchpadActiveId := id
		touchpadLockVerifyTries := 0
		SetTimer, VerifyTouchpadLockTimer, -2500
	} else {
		NotifyTouchpad("Failed to start the touchpad disable command.`nSee touchpad-error.log for details.")
	}
}

;re-enable the touchpad; ownership is only released once the device is confirmed enabled
EnableTouchpadInBackground(id)
{
	global settings, touchpadLockedByUs, touchpadActiveId, touchpadUnlockVerifyTries

	if (id = "")
		id := settings.TouchpadInstanceId()
	if (id = "")
		return

	errorCode := GetDeviceErrorCode(id)
	if (errorCode = -1) {
		touchpadLockedByUs := false
		NotifyTouchpad("The configured touchpad device was not found.`nCheck touchpad-instance-id in settings.ini.")
		return
	}

	touchpadActiveId := id
	touchpadUnlockVerifyTries := 0

	;always issue the enable command: a disable command started at lock time may still be
	;in flight, so a quick lock/unlock/lock cycle could otherwise leave the touchpad disabled
	if (!RunPnpCommand(id, true)) {
		touchpadLockedByUs := false
		NotifyTouchpad("Failed to start the touchpad enable command.`nUse the tray menu or Device Manager.")
		return
	}
	SetTimer, VerifyTouchpadUnlockTimer, -2500
}

;spawn a hidden elevated PowerShell command; returns true if the process was started
RunPnpCommand(id, enable)
{
	static seq := 0
	seq += 1

	psFile := A_Temp . "\keyboard-locker-pnp-" . A_TickCount . "-" . seq . ".ps1"
	logFile := A_ScriptDir . "\touchpad-error.log"
	verb := enable ? "Enable-PnpDevice" : "Disable-PnpDevice"

	code := "$ErrorActionPreference = 'Stop'`n"
	code .= "$ok = $false`n"
	code .= "try {`n"
	code .= "  " . verb . " -InstanceId '" . id . "' -Confirm:$false`n"
	code .= "  $ok = $true`n"
	code .= "} catch {`n"
	code .= "  $_.Exception.Message | Out-File -FilePath '" . logFile . "' -Encoding utf8`n"
	code .= "}`n"
	code .= "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue`n"
	code .= "if (-not $ok) { exit 1 }`n"
	code .= "exit 0`n"

	FileDelete, %psFile%
	FileAppend, %code%, %psFile%
	Run, powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%psFile%",, Hide UseErrorLevel
	if (ErrorLevel) {
		FileDelete, %psFile%
		return false
	}
	return true
}

;auto-detect the built-in touchpad by scoring PnP devices
DetectTouchpadDeviceId()
{
	outFile := A_Temp . "\keyboard-locker-touchpad.tsv"
	psFile := A_Temp . "\keyboard-locker-detect-touchpad.ps1"

	FileDelete, %outFile%
	FileDelete, %psFile%

	;Localized device names. Built from code points so this script file can stay ASCII.
	padCn1 := Chr(0x89E6) . Chr(0x6478) . Chr(0x677F)      ; touchpad (CN)
	padCn2 := Chr(0x89E6) . Chr(0x63A7) . Chr(0x677F)      ; touchpad (CN, alt)
	screenCn := Chr(0x89E6) . Chr(0x6478) . Chr(0x5C4F)    ; touch screen (CN)
	penCn := Chr(0x624B) . Chr(0x5199) . Chr(0x7B14)       ; pen (CN)

	code := "param([string]$OutFile)`n"
	code .= "$ErrorActionPreference = 'SilentlyContinue'`n"
	code .= "$padRe = '(?i)touch.?pad|trackpad|" . padCn1 . "|" . padCn2 . "'`n"
	code .= "$screenRe = '(?i)touch[\s-]*screen|\bpen\b|digitizer|" . screenCn . "|" . penCn . "'`n"
	code .= "$rows = @()`n"
	code .= "foreach ($cls in @('Mouse','HIDClass')) {`n"
	code .= "  Get-PnpDevice -Class $cls -PresentOnly | ForEach-Object {`n"
	code .= "    $id = $_.InstanceId`n"
	code .= "    $name = $_.FriendlyName`n"
	code .= "    $score = 0`n"
	code .= "    if ($name -match $padRe) { $score += 5 }`n"
	code .= "    if ($cls -eq 'Mouse') { $score += 3 }`n"
	code .= "    if ($id -match '^HID\\') { $score += 1 }`n"
	code .= "    if ($id -match '(?i)VID_|BTHENUM|BTHLEDEVICE|^USB\\') { $score -= 10 }`n"
	code .= "    if ($id -match '^ACPI\\') { $score -= 20 }`n"
	code .= "    if ($name -match $screenRe) { $score -= 15 }`n"
	code .= "    $rows += [pscustomobject]@{ Score=$score; Class=$cls; Id=$id; Status=$_.Status }`n"
	code .= "  }`n"
	code .= "}`n"
	code .= "$sorted = @($rows | Sort-Object Score -Descending)`n"
	code .= "if ($sorted.Count -gt 0 -and $sorted[0].Score -ge 3) {`n"
	code .= "  $top = $sorted[0]`n"
	code .= "  $parent = ''`n"
	code .= "  try { $parent = (Get-PnpDeviceProperty -InstanceId $top.Id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data } catch {}`n"
	code .= "  $target = $top.Id`n"
	code .= "  if ($parent -match '^ACPI\\') { $target = $parent }`n"
	code .= "  @($top.Score, $top.Class, $top.Id, $target, $top.Status) -join [char]9 | Set-Content -Path $OutFile -Encoding ASCII`n"
	code .= "}`n"

	f := FileOpen(psFile, "w", "UTF-8")
	if (!IsObject(f))
		return ""
	f.Write(code)
	f.Close()

	RunWait, powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%psFile%" -OutFile "%outFile%",, Hide
	FileDelete, %psFile%

	if (!FileExist(outFile))
		return ""

	FileRead, output, %outFile%
	FileDelete, %outFile%

	;the file contains at most one row: the highest-scoring member device
	Loop, Parse, output, `n, `r
	{
		if (A_LoopField = "")
			continue
		fields := StrSplit(A_LoopField, "`t")
		if (fields.Length() < 4)
			continue
		score := fields[1] + 0
		target := fields[4]
		if (score >= 3 && target != "")
			return target
		break
	}
	return ""
}

;return the Windows problem code for a PnP device (22 = disabled; -1 = not found)
GetDeviceErrorCode(id)
{
	static wmi := 0
	if (wmi = 0)
		wmi := ComObjGet("winmgmts:")

	;Enumerate instead of filtering in WQL: backslashes in an instance ID are treated
	;as escape characters by WQL string literals, so an exact-match query silently fails.
	for device in wmi.ExecQuery("SELECT PNPDeviceID, ConfigManagerErrorCode FROM Win32_PnPEntity")
	{
		if (device.PNPDeviceID = id)
			return device.ConfigManagerErrorCode
	}
	return -1
}

IsDeviceDisabled(id)
{
	return GetDeviceErrorCode(id) = 22
}

;show a tray tip about the touchpad, honoring the "hide tooltips" setting
NotifyTouchpad(message)
{
	global settings
	if (!settings.HideTooltips())
		TrayTip,,%message%,10,2
}

;best-effort: never leave the touchpad disabled after the script exits
CleanupOnExitLabel:
	CleanupOnExit()
return

CleanupOnExit()
{
	global touchpadLockedByUs, touchpadActiveId
	if (touchpadLockedByUs && touchpadActiveId != "") {
		RunPnpCommand(touchpadActiveId, true)
		touchpadLockedByUs := false
	}
	return 0
}

;this is used to block mouse input
doNothing:
return

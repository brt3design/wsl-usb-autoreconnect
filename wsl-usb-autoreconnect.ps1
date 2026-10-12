<#
.SYNOPSIS
    WSL USB Auto-Reconnect TUI - Persistent Device Mounter

.DESCRIPTION
    A flicker-free, fully asynchronous Text User Interface (TUI) for usbipd.
    CORE FEATURE: "Persistent Auto-Reconnect". Once a USB device (VID) is locked, 
    this script will automatically bind and attach it to WSL in the background 
    every time it is unplugged, rebooted, or changes states. 
    
    Particularly useful for embedded system developers (e.g., NVIDIA Jetson Orin 
    flashing) where devices frequently reboot and drop USB connections during 
    the flashing process.

    [Features]
    - Asynchronous execution (UI never freezes)
    - Auto-reconnection for targeted VIDs
    - Terminal window resize & buffer reflow glitch resolved
    - Mutex handle leak issue resolved (safe for multiple terminals)

.LICENSE
    MIT License
#>

$mutexName = "Global\WSL_USB_AutoReconnect_Mutex"
$mutexCreated = $false

# Request initial ownership of the Mutex
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)

# If we didn't create it, another instance is running. 
# We MUST dispose the handle we just grabbed, otherwise this terminal holds it hostage!
if (-not $mutexCreated) {
	Write-Warning "[ERROR] Another instance of WSL USB Auto-Reconnect is already running! Terminating."
    if ($null -ne $mutex) { $mutex.Dispose() }
    Start-Sleep -Seconds 2
    exit
}

# Wrap the ENTIRE script in Try-Finally to guarantee Mutex release under ALL circumstances
try {
    #region [1] Environment Initialization
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning "[ERROR] Please run this script as Administrator!"
        Start-Sleep -Seconds 2
        exit # This will safely trigger the finally block to release the Mutex
    }

    [console]::TreatControlCAsInput = $true
    [console]::CursorVisible = $false

    $targetVids    = [System.Collections.Generic.HashSet[string]]::new()
    $activeTasks   = @{}  
    $isRunning     = $true
    $isCleaningUp  = $false
    $lastMessage   = ""
    $messageTime   = [DateTime]::MinValue
    $previousLines = 0    

	# Track last window size to handle resize events and prevent buffer reflow glitches
	$lastWindowWidth  = -1
    $lastWindowHeight = -1

    Clear-Host
    $startY = 0
    #endregion

    #region [1.5] Async Workers
    function Start-UsbipdTask {
        param([string]$Command)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c $Command"
        $psi.WindowStyle = 'Hidden'
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        return [System.Diagnostics.Process]::Start($psi)
    }
	
	# Calculates visual width, treating CJK characters as 2 spaces
    function Get-VisualWidth ([string]$str) {
        if ([string]::IsNullOrEmpty($str)) { return 0 }
        $cjkCount = [regex]::Matches($str, '[\u4e00-\u9fa5\u3000-\u303f\uff01-\uffee]').Count
        return $str.Length + $cjkCount
    }

	# Safely truncates string based on visual width to prevent automatic terminal word-wrap
    function Truncate-VisualWidth ([string]$str, [int]$maxWidth) {
        if ($maxWidth -le 0) { return "" }
        $currentW = 0
        $sb = [System.Text.StringBuilder]::new()
        foreach ($ch in $str.ToCharArray()) {
            $cw = if ([regex]::IsMatch($ch, '[\u4e00-\u9fa5\u3000-\u303f\uff01-\uffee]')) { 2 } else { 1 }
            if ($currentW + $cw -gt $maxWidth) { break }
            $null = $sb.Append($ch)
            $currentW += $cw
        }
        return $sb.ToString()
    }
    #endregion

    #region [2] Main TUI Loop
    while ($isRunning -and -not $isCleaningUp) {
        
        # Detect window resize; clear screen and reset baseline if changed to prevent cursor misalignment
        $currentWidth  = [Console]::WindowWidth
        $currentHeight = [Console]::WindowHeight

        if ($currentWidth -ne $lastWindowWidth -or $currentHeight -ne $lastWindowHeight) {
            Clear-Host
            $lastWindowWidth  = $currentWidth
            $lastWindowHeight = $currentHeight
            $previousLines    = 0
            $startY           = 0
        }

		# Reserve 1 space to prevent boundary auto-scrolling, set minimum width to avoid exceptions
        $consoleWidth = [Math]::Max($currentWidth - 1, 20)
        
		# Clean up finished async tasks
        $completedTasks = @()
        foreach ($busId in $activeTasks.Keys) {
            if ($activeTasks[$busId].Process.HasExited) {
                $completedTasks += $busId
            }
        }
        foreach ($busId in $completedTasks) {
            $activeTasks.Remove($busId)
        }
		
		# Fetch and parse USB devices
        $usbipdOutput = usbipd list
        $deviceList   = @()
        $deviceIndex  = 1
        
        foreach ($line in $usbipdOutput) {
            if ($line -match "^\s*(\d+(?:-\d+)+)\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+(.*?)\s{2,}(.*)$") {
                
                $keyChar = if ($deviceIndex -le 9) { $deviceIndex.ToString() } 
                           elseif ($deviceIndex -le 35) { [char](55 + $deviceIndex) } 
                           else { "?" }
                
                $deviceList += [PSCustomObject]@{
                    KeyChar = $keyChar
                    BusId   = $matches[1]
                    Vid     = $matches[2].ToLower()
                    Pid     = $matches[3].ToLower()
                    Name    = $matches[4].Trim()
                    State   = $matches[5].Trim()
                }
                $deviceIndex++
            }
        }
		
		# Core Feature: Auto-Reconnect Locked Devices
        foreach ($dev in $deviceList) {
            if ($targetVids.Contains($dev.Vid)) {
                if (-not $activeTasks.ContainsKey($dev.BusId)) {
                    if ($dev.State -match "Not shared") {
                        $activeTasks[$dev.BusId] = [PSCustomObject]@{
                            Process = Start-UsbipdTask "usbipd bind --busid $($dev.BusId) --force"
                            Action  = "Binding..."
                        }
                    } elseif ($dev.State -match "Shared" -or $dev.State -match "Not attached") {
                        $activeTasks[$dev.BusId] = [PSCustomObject]@{
                            Process = Start-UsbipdTask "usbipd attach --wsl --busid $($dev.BusId)"
                            Action  = "Attaching..."
                        }
                    }
                }
            }
        }
			
		# Reset cursor for flicker-free redrawing
        try {
            [Console]::SetCursorPosition(0, $startY)
        } catch {
            Clear-Host
            $startY = 0
            [Console]::SetCursorPosition(0, $startY)
        }

        $linesThisFrame = 0 
		
		# Helper function for rendering truncated and padded text rows
        $WriteLine = {
            param([string]$Text, [string]$Color = "White")
            # 1. Safely truncate by visual width to guarantee no word-wrap
            $safeText = Truncate-VisualWidth $Text $consoleWidth
            # 2. Pad remaining space with blanks to overwrite previous frame's ghosting
            $vWidth   = Get-VisualWidth $safeText
            $padLen   = [Math]::Max(0, $consoleWidth - $vWidth)
            Write-Host ($safeText + (" " * $padLen)) -ForegroundColor $Color
            Set-Variable -Name linesThisFrame -Value ($linesThisFrame + 1) -Scope Script
        }
        
        # Dynamic responsive separators based on window width
        $sepEqual = "=" * $consoleWidth
        $sepDash  = "-" * $consoleWidth

        &$WriteLine $sepEqual "Cyan"
        &$WriteLine "  >>> WSL USB Auto-Reconnect Panel" "White"
        &$WriteLine $sepEqual "Cyan"
		
        # Standardized row template
        $rowTemplate = "{0,-7} | {1,-7} | {2,-9} | {3,-14} | {4}"
        
        &$WriteLine ($rowTemplate -f " [KEY]", "BUSID", "VID:PID", "STATE", "DEVICE NAME") "Yellow"
        &$WriteLine $sepDash "Gray"
        
        if ($deviceList.Count -eq 0) {
            &$WriteLine "  (No USB devices found)" "DarkGray"
        } else {
            foreach ($dev in $deviceList) {
                $isTarget = $targetVids.Contains($dev.Vid)
                $rowColor = if ($isTarget) { "Green" } else { "White" }
                $lockMark = if ($isTarget) { " [LOCKED]" } else { "" }

                $displayState = if ($activeTasks.ContainsKey($dev.BusId)) {
                    "~ " + $activeTasks[$dev.BusId].Action
                } else {
                    $dev.State
                }

                $keyFormatted    = "  [$($dev.KeyChar)]"
                $vidPidFormatted = "$($dev.Vid):$($dev.Pid)"
                $nameFormatted   = "$($dev.Name)$lockMark"
				
                $lineText = $rowTemplate -f $keyFormatted, $dev.BusId, $vidPidFormatted, $displayState, $nameFormatted
                &$WriteLine $lineText $rowColor
            }
        }
        &$WriteLine $sepDash "Gray"
        
		# Display status messages for 3 seconds
        if ((Get-Date) -lt $messageTime.AddSeconds(3)) {
            &$WriteLine " [*] $lastMessage" "Magenta"
        } else { 
            &$WriteLine "" "White" 
        }

        &$WriteLine "" "White"
        &$WriteLine " INSTRUCTIONS:" "Cyan"
        &$WriteLine "  -> Press [0-9/A-Z] to toggle target lock (auto-bind/attach)" "White"
        &$WriteLine "  -> Press [Q] or [Ctrl+C] to detach/unbind and exit" "White"
        
        # Clear extra lines from previous frame (e.g., when device count drops)
        if ($previousLines -gt $linesThisFrame) {
            for ($i = $linesThisFrame; $i -lt $previousLines; $i++) {
                Write-Host (" " * $consoleWidth)
            }
        }
        $previousLines = $linesThisFrame
		
		# Handle user input asynchronously (500ms tick)
        $tickTimeout = (Get-Date).AddMilliseconds(500) 
        $keyPressed  = $null
        
        while ((Get-Date) -lt $tickTimeout) {
            if ([console]::KeyAvailable) {
                $keyInfo = [System.Console]::ReadKey($true)
                if ($keyInfo.Key -eq 'Q' -or ($keyInfo.Key -eq 'C' -and $keyInfo.Modifiers -match 'Control')) {
                    $isRunning = $false
                    break
                }
                $keyPressed = $keyInfo.KeyChar.ToString().ToUpper()
                break
            }
            Start-Sleep -Milliseconds 50
        }

        if (-not $isRunning) { break }
		
		# Process keystrokes to toggle lock status
        if ($keyPressed) {
            $selectedDev = $deviceList | Where-Object { $_.KeyChar -eq $keyPressed }
            if ($selectedDev) {
                $targetVid = $selectedDev.Vid
                $messageTime = Get-Date
                
                if ($targetVids.Contains($targetVid)) {
                    $targetVids.Remove($targetVid) | Out-Null
                    $deviceList | Where-Object { $_.Vid -eq $targetVid } | ForEach-Object {
                        $activeTasks[$_.BusId] = [PSCustomObject]@{
                            Process = Start-UsbipdTask "usbipd detach --busid $($_.BusId) & usbipd unbind --busid $($_.BusId)"
                            Action  = "Releasing..."
                        }
                    }
                    $lastMessage = "Unlocked VID: $targetVid (Releasing in background...)"
                } else {
                    $targetVids.Add($targetVid) | Out-Null
                    $lastMessage = "Locked VID: $targetVid (Auto-reconnecting...)"
                }
            }
        }
    }
    #endregion
    
} finally {
    #region [3] Graceful Exit & Mutex Cleanup
    $isCleaningUp = $true
    
    # Only run USB release logic if variables were successfully initialized
    if ($null -ne $targetVids) {
        while ([console]::KeyAvailable) { $null = [System.Console]::ReadKey($true) }
        
        try {
            [Console]::SetCursorPosition(0, $startY + $previousLines)
        } catch {
            Write-Host ""
        }
        
        Write-Host "`n[!] Exit command received. Safely releasing devices, please wait..." -ForegroundColor Yellow
        
        $finalOutput = usbipd list
        $releaseList = @()
        
        foreach ($line in $finalOutput) {
            if ($line -match "^\s*(\d+(?:-\d+)+)\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})") {
                $busid = $matches[1]
                $vid   = $matches[2].ToLower()
                if ($targetVids.Contains($vid)) {
                    Write-Host "  -> Detaching from WSL (BUSID: $busid)..." -ForegroundColor Gray
                    usbipd detach --busid $busid *>&1 | Out-Null
                    $releaseList += $busid
                }
            }
        }
        
        if ($releaseList.Count -gt 0) {
            Write-Host "  -> Waiting for Windows USB stack to recover (1 sec)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 1 
            foreach ($busid in $releaseList) {
                Write-Host "  -> Unbinding from usbipd (BUSID: $busid)..." -ForegroundColor Gray
                usbipd unbind --busid $busid *>&1 | Out-Null
            }
        }
    }
    
    [console]::TreatControlCAsInput = $false
    [console]::CursorVisible = $true
    
    # ABSOLUTE GUARANTEE: Free the Mutex if we own it
    if ($mutexCreated -and ($null -ne $mutex)) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    
    Write-Host "[OK] Cleanup complete. Script exited safely." -ForegroundColor Green
    #endregion
}
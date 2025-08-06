Import-Module -Force $PSScriptRoot/Set-Window

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
  using System;
  using System.Runtime.InteropServices;

  // declare the EnumWindowsProc delegate type
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  public class WindowUtil {
    // Notice EnumWindows() is now `public`
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll",SetLastError=true)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  }

  public struct RECT {
    public int Left;        // x position of upper-left corner
    public int Top;         // y position of upper-left corner
    public int Right;       // x position of lower-right corner
    public int Bottom;      // y position of lower-right corner
  }
'@

# done this way so that the RECT type is accessible
Invoke-Expression @'
  class WindowInfo {
    [IntPtr]$Handle
    [UInt32]$ProcessId
    [Bool]$Maximized

    WindowInfo([IntPtr]$h, [UInt32]$p, [Bool]$m) {
      $this.Handle = $h
      $this.ProcessId = $p
      $this.Maximized = $m
    }

    [string]ToString() {
      return ("WindowInfo(pid={0}, handle={1}, maximized={2})" -f $this.ProcessId, $this.Handle, $this.Maximized)
    }
  }
'@

$AllScreens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object -Property { $_.WorkingArea.X }
# default to right-most screen
$ScreenIndex = -1
if ($args.Count -gt 0 -and $args.Count -lt 2) {
  $ScreenIndex = [int]$args[0] - 1
}
if (($ScreenIndex -gt ($AllScreens.Count + 1))) {
  Write-Error "Screen index out-of-bounds, max index: $($AllScreens.Count)"
  return
} elseif ($ScreenIndex -lt 0) {
    $TargetScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary }
} else {
    $TargetScreen = $AllScreens[$ScreenIndex]
}


foreach ($s in $AllScreens) {
  Write-Debug ("[Monitor {0}] Size: {1}x{2} | Position: ({3}, {4})" -f
    ($AllScreens.IndexOf($s) + 1),
    $s.WorkingArea.Width, $s.WorkingArea.Height,
    $s.WorkingArea.X, $s.WorkingArea.Y
  )
}

$TargetScreenX = $TargetScreen.WorkingArea.X
$TargetScreenY = $TargetScreen.WorkingArea.Y
$TargetScreenWidth = $TargetScreen.WorkingArea.Width
$TargetScreenHeight = $TargetScreen.WorkingArea.Height

$ExcludedProcessNames = @('ApplicationFrameHost')

# Create a list to act as a receptacle for all the window handles we're about to enumerate
$WindowHandles = [System.Collections.Generic.List[IntPtr]]::new()

# Define the callback function
$callback = {
  param([IntPtr]$handle, [IntPtr]$param)

  # Copy the window handle to our list
  $WindowHandles.Add($handle)

  # Continue (return $false from the callback to abort the enumeration)
  return $true
}

if(![WindowUtil]::EnumWindows($callback, [IntPtr]::Zero)) {
  Write-Error 'Unable to enum windows'
  return
}

# $WindowHandles will contain all the window handles now
$processHandles = @{}
foreach($windowHandle in $WindowHandles) {
  #if (![WindowUtil]::IsWindowVisible($windowHandle)) {
  #  Continue
  #}

  $automationElement = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
  $pattern = $null
  if(!$automationElement.TryGetCurrentPattern([System.Windows.Automation.WindowPatternIdentifiers]::Pattern, [ref]$pattern)) {
    Continue
  }
  $isMaximized = ($pattern.Current.WindowVisualState -eq 'Maximized')

  [UInt32]$processId = 0
  [void][WindowUtil]::GetWindowThreadProcessId($windowHandle, [ref]$processId)
  if ($processId -eq 0) {
    Continue
  }

  if (!$processHandles.Contains($processId)) {
    $processHandles[$processId] = @()
  }
  $processHandles[$processId] += [WindowInfo]::new($windowHandle, $processId, $isMaximized)
}

foreach ($p in $processHandles.GetEnumerator()) {
  $processId, $procWindowHandles = $p.Name, $p.Value

  $processName = (Get-Process -Id $processId).ProcessName
  if ($ExcludedProcessNames.Contains($processName)) {
    Continue
  }

  Write-Debug "${processName} ($($processId)): $($procWindowHandles)"
  :windowHandleLoop foreach ($windowInfo in $procWindowHandles) {
    $windowHandle = $windowInfo.Handle
    $windowTextLength = [WindowUtil]::GetWindowTextLength($windowHandle)
    if ($windowTextLength -eq 0) {
      Continue
    }

    if ($windowInfo.Maximized) {
      Write-Debug 'Restoring window...'
      [void][WindowUtil]::ShowWindow($windowHandle, 1)
    }

    $windowRect = New-Object RECT

    [void][WindowUtil]::GetWindowRect($windowHandle, [ref]$windowRect)
    $windowHeight = $windowRect.Bottom - $windowRect.Top
    $windowWidth = $windowRect.Right - $windowRect.Left

    # scale down width/height to fit on other monitor
    $newWindowHeight = $newWindowWidth = $newWindowX = $newWindowY = 0

    $windowNeedsMovement = $false
    foreach ($screen in $AllScreens) {
      $screenX = $screen.WorkingArea.X
      $screenY = $screen.WorkingArea.Y
      $screenWidth = $screen.WorkingArea.Width
      $screenHeight = $screen.WorkingArea.Height

      $windowX = $windowRect.Left
      $windowY = $windowRect.Top

      # check if the window is on the $screen in the loop
      if (($windowX -lt $screenX) -or ($windowX -ge ($screenX + $screenWidth))) {
        Continue
      }

      if ($screen -eq $TargetScreen) {
        Write-Debug 'Window is already on target screen'
        Continue
      }

      # $screen is now the current screen the window is on
      # $TargetScreen is the screen we want the window to be on

      Write-Debug ("Target Screen: {0} | Screen: {1}" -f $TargetScreen, $screen)

      $newWindowWidth = $windowWidth
      if ($newWindowWidth -gt $TargetScreenWidth) {
        $newWindowWidth = [int](($windowWidth / $screenWidth) * $TargetScreenWidth)
      }

      $newWindowHeight = $windowHeight
      if ($newWindowHeight -gt $TargetScreenHeight) {
        $newWindowHeight = [int](($windowHeight / $screenHeight) * $TargetScreenHeight)
      }

      # scale X position of window to target monitor
      $xRatio = ($windowX - $screenX) / $screenWidth
      $newWindowX = [int]($xRatio * $TargetScreenWidth) + $TargetScreenX

      # scale Y position of window to target monitor
      $yRatio = ($windowY - $screenY) / $screenHeight
      $newWindowY = [int]($yRatio * $TargetScreenHeight) + $TargetScreenY

      $windowNeedsMovement = $true
      Break
    }


    if ($windowNeedsMovement) {
      Write-Debug 'Moving window...'
      Set-Window -Handle $windowHandle -X $newWindowX -Y $newWindowY -Height $newWindowHeight -Width $newWindowWidth
      Set-Window -Handle $windowHandle -X $newWindowX -Y $newWindowY -Height $newWindowHeight -Width $newWindowWidth
    }

    if ($windowInfo.Maximized) {
      Write-Debug 'Maximizing window...'
      [void][WindowUtil]::ShowWindow($windowHandle, 3)
    }


    if ($DebugPreference -ne 'SilentlyContinue') {
      $windowTitleSb = [System.Text.StringBuilder]::new($windowTextLength + 1)
      $null = [WindowUtil]::GetWindowText($windowHandle, $windowTitleSb, $windowTitleSb.Capacity)
      $windowTitle = $windowTitleSb.ToString()

      $newWindowRect = New-Object RECT
      [void][WindowUtil]::GetWindowRect($windowHandle, [ref]$newWindowRect)
      $logMessage = ("  - {0}: {1}" -f $windowHandle, $windowTitle)

      if ($windowNeedsMovement) {
        $logMessage = ("{0} | Old: {1}x{2} @ ({3}, {4}) | New: {5}x{6} @ ({7}, {8})" -f
          $logMessage,
          $windowWidth, $windowHeight, $windowRect.Left, $windowRect.Top,
          $newWindowWidth, $newWindowHeight, $newWindowX, $newWindowY
        )
      }

      $logMessage = ("{0} | Current: {1}x{2} @ ({3}, {4}) ({5}, {6})" -f
        $logMessage,
        ($newWindowRect.Right - $newWindowRect.Left), ($newWindowRect.Bottom - $newWindowRect.Top),
        $newWindowRect.Left, $newWindowRect.Top, $newWindowRect.Right, $newWindowRect.Bottom
      )

      Write-Debug $logMessage
    }
  }
}
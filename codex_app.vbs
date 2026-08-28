' Codex Desktop Launcher - dynamically resolves codex.exe path
' No console flash, no hardcoded hash directory
' Strategy 1: Read CODEX_CLI_PATH from ~/.codex/config.toml
' Strategy 2: Scan bin subdirectories for newest codex.exe
' Strategy 3: Fall back to PATH

' === NEW: Dynamic ip-switch service detection and startup ===
Function StartAndDetectIpSwitchService()
    On Error Resume Next
    Set WshShell = CreateObject("WScript.Shell")
    Set fso = CreateObject("Scripting.FileSystemObject")
    
    ipSwitchPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\ip-switch\dist\index.js"
    ipSwitchDir = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\ip-switch"
    servicePort = ""
    
    ' Check if ip-switch process is already running and get its port
    Set process = GetObject("winmgmts:\\.\root\cimv2:Win32_Process")
    ipSwitchAlreadyRunning = False
    
    For Each p In process.ExecQuery("SELECT * FROM Win32_Process WHERE Name='node.exe'")
        If InStr(p.CommandLine, "ip-switch") > 0 Then
            ' Extract port from command line
            cmdLine = p.CommandLine
            portMatch = RegExpTest(cmdLine, "--port\s+(\d+)")
            If portMatch Then
                servicePort = portMatch
            Else
                ' If no port found, try default port 54035
                servicePort = "54035"
            End If
            ipSwitchAlreadyRunning = True
            Exit For
        End If
    Next
    
    ' If not running, start ip-switch service
    If Not ipSwitchAlreadyRunning Then
        If fso.FolderExists(ipSwitchDir) And fso.FileExists(ipSwitchPath) Then
            ' Start service and capture output to get port
            Set exec = WshShell.Exec("cmd /c cd " & ipSwitchDir & " && node " & ipSwitchPath)
            
            ' Wait for service to start and find port
            startTime = Timer
            portFound = False
            
            Do While Timer < startTime + 30 ' Wait up to 30 seconds
                Do While Not exec.StdOut.AtEndOfStream
                    line = exec.StdOut.ReadLine()
                    portMatch = RegExpTest(line, "Server running on port (\d+)")
                    If portMatch Then
                        servicePort = portMatch
                        portFound = True
                        Exit Do
                    End If
                Loop
                
                If portFound Then Exit Do
                
                ' Also check if process is running with port
                Set process2 = GetObject("winmgmts:\\.\root\cimv2:Win32_Process")
                For Each p In process2.ExecQuery("SELECT * FROM Win32_Process WHERE Name='node.exe'")
                    If InStr(p.CommandLine, "ip-switch") > 0 Then
                        cmdLine = p.CommandLine
                        portMatch = RegExpTest(cmdLine, "--port\s+(\d+)")
                        If portMatch Then
                            servicePort = portMatch
                            portFound = True
                            Exit For
                        End If
                    End If
                Next
                
                If portFound Then Exit Do
                WScript.Sleep 1000 ' Wait 1 second before checking again
            Loop
            
            If Not portFound Then
                ' Fallback to default port if not detected
                servicePort = "54035"
            End If
            
            ' Wait additional time for service to be fully ready
            WScript.Sleep 2000
        End If
    End If
    
    StartAndDetectIpSwitchService = servicePort
End Function

' Helper function for regular expression matching
Function RegExpTest(input, pattern)
    Set regex = New RegExp
    regex.Pattern = pattern
    regex.IgnoreCase = True
    
    If regex.Test(input) Then
        Set matches = regex.Execute(input)
        If matches.Count > 0 Then
            RegExpTest = matches(0).SubMatches(0)
            Exit Function
        End If
    End If
    RegExpTest = ""
End Function

' === END NEW CODE ===

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Start ip-switch service and get dynamic port
ipSwitchPort = StartAndDetectIpSwitchService()

codexPath = ""

' --- Strategy 1: Read CODEX_CLI_PATH from config.toml ---
configPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.codex\config.toml"
If fso.FileExists(configPath) Then
    Set configFile = fso.OpenTextFile(configPath, 1)
    Do Until configFile.AtEndOfStream
        line = Trim(configFile.ReadLine)
        If Left(line, 15) = "CODEX_CLI_PATH" Then
            ' Try single quotes: CODEX_CLI_PATH = '...'
            p1 = InStr(line, "'")
            If p1 > 0 Then
                p2 = InStr(p1 + 1, line, "'")
                If p2 > p1 Then codexPath = Mid(line, p1 + 1, p2 - p1 - 1)
            End If
            ' Try double quotes if single not found
            If codexPath = "" Then
                p1 = InStr(line, """")
                If p1 > 0 Then
                    p2 = InStr(p1 + 1, line, """")
                    If p2 > p1 Then codexPath = Mid(line, p1 + 1, p2 - p1 - 1)
                End If
            End If
            Exit Do
        End If
    Loop
    configFile.Close
End If

' --- Strategy 2: Scan bin subdirectories for newest codex.exe ---
If codexPath = "" Or Not fso.FileExists(codexPath) Then
    codexPath = ""
    binDir = WshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\OpenAI\Codex\bin"
    If fso.FolderExists(binDir) Then
        newestDate = #1/1/1970#
        Set binFolder = fso.GetFolder(binDir)
        For Each subFolder In binFolder.SubFolders
            candidate = subFolder.Path & "\codex.exe"
            If fso.FileExists(candidate) Then
                If subFolder.DateLastModified > newestDate Then
                    newestDate = subFolder.DateLastModified
                    codexPath = candidate
                End If
            End If
        Next
    End If
End If

' --- Launch ---
If codexPath <> "" And fso.FileExists(codexPath) Then
    WshShell.Run """" & codexPath & """ app", 0, False
Else
    ' Strategy 3: Fall back to PATH
    WshShell.Run "codex app", 0, False
End If

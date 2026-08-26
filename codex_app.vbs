' Codex Desktop Launcher - dynamically resolves codex.exe path
' No console flash, no hardcoded hash directory
' Strategy 1: Read CODEX_CLI_PATH from ~/.codex/config.toml
' Strategy 2: Scan bin subdirectories for newest codex.exe
' Strategy 3: Fall back to PATH

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

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

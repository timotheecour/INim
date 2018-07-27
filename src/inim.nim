# MIT License
# Copyright (c) 2018 Andrei Regiani
import os, osproc, rdstdin, strutils, terminal, times, strformat

type App = ref object
    ## cmd line options
    nim: string
    srcFile: string
    showHeader: bool
    interactive: bool
    ## state (TODO: split from cmd line options)
    fileData: string # used when srcFile is used

## TODO: avoid global variables
var app:App

const
    INimVersion = "0.3.2"
    indentSpaces = "    "
    indentTriggers = [",", "=", ":", "var", "let", "const", "type", "import", 
                      "object", "enum"] # endsWith
    
let
    uniquePrefix = epochTime().int
    bufferSource = getTempDir() & "inim_" & $uniquePrefix & ".nim"

proc compileCode():auto =
    # PENDING https://github.com/nim-lang/Nim/issues/8312, remove redundant `--hint[source]=off`
    let compileCmd = fmt"{app.nim} compile --run --verbosity=0 --hints=off --hint[source]=off --path=./ {bufferSource}"
    result = execCmdEx(compileCmd)

var
    currentOutputLine = 0 # Last line shown from buffer's stdout
    validCode = "" # All statements compiled succesfully
    tempIndentCode = "" # Later append to `validCode` if whole block compiles well
    indentLevel = 0 # Current
    buffer: File

proc getNimVersion*(): string =
    let (output, status) = execCmdEx(fmt"{app.nim} --version")
    doAssert status == 0, fmt"make sure {app.nim} is in PATH"
    result = output.splitLines()[0]

proc getNimPath(): string =
    # TODO: use `which` PENDING https://github.com/nim-lang/Nim/issues/8311
    when defined(Windows):
        let which_cmd = fmt"where {app.nim}"
    else:
        let which_cmd = fmt"which {app.nim}"
    let (output, status) = execCmdEx(which_cmd)
    if status == 0:
        return " at " & output
    return "\n"

proc welcomeScreen() =
    stdout.setForegroundColor(fgCyan)
    stdout.writeLine "👑 INim ", INimVersion
    stdout.write getNimVersion()
    stdout.write getNimPath()
    stdout.resetAttributes()
    stdout.flushFile()

proc cleanExit() {.noconv.} =
    buffer.close()
    removeFile(bufferSource) # Temp .nim
    let exe = bufferSource.changeFileExt(ExeExt)
    removeFile(exe)
    removeDir(getTempDir() & "nimcache")
    quit(0)

proc getFileData(path: string): string =
    try:
        result = path.readFile()
    except:
        result = nil

proc compilationSuccess(current_statement, output: string) =
    if len(tempIndentCode) > 0:
        validCode &= tempIndentCode
    else:
        validCode &= current_statement & "\n"
    let lines = output.splitLines
    
    # Print only output you haven't seen
    stdout.setForegroundColor(fgCyan, true)
    let new_lines = lines[currentOutputLine..^1]
    
    for index, line in new_lines:
        # Skip last empty line (otherwise blank line is displayed after command)
        if index+1 == len(new_lines) and line == "":
            continue
        echo line

    currentOutputLine = len(lines)-1
    stdout.resetAttributes()
    stdout.flushFile()

proc bufferRestoreValidCode() =
    buffer.close()
    buffer = open(bufferSource, fmWrite)
    buffer.write(validCode)
    buffer.flushFile()

proc showError(output: string) =
    # Runtime errors:
    if output.contains("Error: unhandled exception:"):
        stdout.setForegroundColor(fgRed, true)
        # Display only the relevant lines of the stack trace
        let lines = output.splitLines()
        for line in lines[len(lines)-6 .. len(lines)-3]:
            echo line
        stdout.resetAttributes()
        stdout.flushFile()
        return

    # Compilation errors:

    # Prints only relevant message without file and line number info.
    # e.g. "inim_1520787258.nim(2, 6) Error: undeclared identifier: 'foo'"
    # Becomes: "Error: undeclared identifier: 'foo'"
    let pos = output.find(")") + 2
    var message = output[pos..^1].strip

    # Discarded error: shortcut to print values: >>> foo
    if message.endsWith("discarded"):
        # Remove text bloat to result into: foo'int
        message = message.replace("Error: expression '")
        message = message.replace(" is of type '")
        message = message.replace("' and has to be discarded")

        # Make split char to be a semicolon instead of a single-quote
        # To avoid char type conflict having single-quotes
        message[message.rfind("'")] = ';' # last single-quote

        let message_seq = message.split(";") # foo;int  |  'a';char
        let symbol_identifier = message_seq[0] # foo
        let symbol_type = message_seq[1] # int
        let shortcut = "echo " & symbol_identifier & ", \" : " & symbol_type & "\""

        buffer.writeLine(shortcut)
        buffer.flushFile()

        let (output, status) = compileCode()
        if status == 0:
            compilationSuccess(shortcut, output)
        else:
            bufferRestoreValidCode()
            showError(output)

    # Display all other errors
    else:
        stdout.setForegroundColor(fgRed, true)
        echo message
        stdout.resetAttributes()
        stdout.flushFile()

proc init(preload: string = nil) =
    setControlCHook(cleanExit)

    buffer = open(bufferSource, fmWrite)
    if preload == nil:
        # First dummy compilation so next one is faster
        discard compileCode()
        return

    buffer.writeLine(preload)
    buffer.flushFile()
    # Check preloaded file compiles succesfully
    let (output, status) = compileCode()
    if status == 0:
        compilationSuccess(preload, output)
    # Compilation error
    else:
        showError(output)
        bufferRestoreValidCode()
        return

proc getPromptSymbol(): string =
    if indentLevel == 0:
        result = "inim> "
    else:
        result =  "... "
    # Auto-indent (multi-level)
    result &= indentSpaces.repeat(indentLevel)

proc hasIndentTrigger*(line: string): bool =
    if line.len > 0:
        for trigger in indentTriggers:
            if line.strip().endsWith(trigger):
                result = true

proc runForever() =
    while true:
        # Read line
        var myline: string
        try:
            myline = readLineFromStdin(getPromptSymbol()).strip
        except IOError:
            return

        # Special commands
        if myline in ["exit", "quit()"]:
            cleanExit()

        # Empty line: exit indent level, otherwise do nothing
        if myline == "":
            if indentLevel > 0:
                indentLevel -= 1
            elif indentLevel == 0:
                continue

        # Write your line to buffer(temp) source code
        buffer.writeLine(indentSpaces.repeat(indentLevel) & myline)
        buffer.flushFile()

        # Check for indent
        if myline.hasIndentTrigger():
            indentLevel += 1

        # Don't run yet if still on indent
        if indentLevel != 0:
            # Skip indent for first line
            if myline.hasIndentTrigger():
                tempIndentCode &= indentSpaces.repeat(indentLevel-1) & myline & "\n"
            else:
                tempIndentCode &= indentSpaces.repeat(indentLevel) & myline & "\n"
            continue

        # Compile buffer
        let (output, status) = compileCode()

        # Succesful compilation, expression is valid
        if status == 0:
            compilationSuccess(myline, output)

        # Compilation error
        else:
            # Write back valid code to buffer
            bufferRestoreValidCode()
            showError(output)
            indentLevel = 0

        # Clean up
        tempIndentCode = ""

proc main(nim="nim", srcFile = "", showHeader = true, interactive = true) =
    ## inim interpreter
    app.new()
    app.nim=nim
    app.srcFile=srcFile
    app.showHeader=showHeader
    app.interactive=interactive

    if app.showHeader: welcomeScreen()

    var fileData: string
    if srcFile.len > 0:
        doAssert(srcFile.fileExists, "cannot access " & srcFile)
        doAssert srcFile.splitFile.ext == ".nim"
        app.fileData = getFileData(srcFile)
    init(app.fileData)
    runForever()

when isMainModule:
    import cligen
    dispatch(main, help = {
            "nim": "path to nim compiler",
            "srcFile": "nim script to preload/run",
            "showHeader": "show program info startup",
            "interactive": "when false, exits when script finishes running",
        })

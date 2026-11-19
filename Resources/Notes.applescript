on sameText(firstText, secondText)
    return (id of firstText) = (id of secondText)
end sameText

on marginFolder(createIfMissing)
    tell application "/System/Applications/Notes.app"
        if not (exists account "iCloud") then error "Enable iCloud Notes on this Mac, then try again." number 1700
        set cloudAccount to account "iCloud"
        set matches to every folder of cloudAccount whose name is "Margin"
        if (count matches) > 1 then error "Keep one Margin folder in iCloud Notes, then try again." number 1700
        if (count matches) = 1 then return item 1 of matches
        if not createIfMissing then error "The Margin folder is missing from iCloud Notes. Reconnect to create it." number 1700
        return make new folder at cloudAccount with properties {name:"Margin"}
    end tell
end marginFolder

on noteInFolder(noteID)
    set targetFolder to my marginFolder(false)
    tell application "/System/Applications/Notes.app"
        set matches to every note of targetFolder whose id is noteID
        if (count matches) = 0 then return missing value
        return item 1 of matches
    end tell
end noteInFolder

on noteRow(targetNote)
    tell application "/System/Applications/Notes.app"
        set noteID to id of targetNote
        set noteName to name of targetNote
        if password protected of targetNote then return {noteID, noteName, "", "", false}
        set canEdit to (not (shared of targetNote)) and ((count attachments of targetNote) = 0)
        return {noteID, noteName, plaintext of targetNote, body of targetNote, canEdit}
    end tell
end noteRow

on run
    return true
end run

on connectnotes()
    my marginFolder(true)
    return true
end connectnotes

on listnotes()
    set targetFolder to my marginFolder(false)
    set rows to {}
    tell application "/System/Applications/Notes.app"
        repeat with targetNote in (get every note of targetFolder)
            set end of rows to my noteRow(contents of targetNote)
        end repeat
    end tell
    return rows
end listnotes

on getnote(noteID)
    set targetNote to my noteInFolder(noteID)
    if targetNote is missing value then return {}
    return my noteRow(targetNote)
end getnote

on createnote(newBody)
    set targetFolder to my marginFolder(false)
    tell application "/System/Applications/Notes.app"
        set newNote to make new note at targetFolder with properties {body:newBody}
        return id of newNote
    end tell
end createnote

on updatenote(noteID, expectedBody, newBody)
    set targetNote to my noteInFolder(noteID)
    if targetNote is missing value then error "This note is no longer in the Margin folder." number 1700
    tell application "/System/Applications/Notes.app"
        if password protected of targetNote or shared of targetNote or ((count attachments of targetNote) > 0) then error "Edit this note in Apple Notes." number 1700
        if not my sameText(body of targetNote, expectedBody) then error "This note changed in Apple Notes. Reopen it to see the latest version." number 1700
        set body of targetNote to newBody
    end tell
    return true
end updatenote

on opennote(noteID)
    set targetNote to my noteInFolder(noteID)
    if targetNote is missing value then error "This note is no longer in the Margin folder." number 1700
    tell application "/System/Applications/Notes.app"
        show targetNote
        activate
    end tell
    return true
end opennote

on deletenote(noteID, expectedBody)
    set targetNote to my noteInFolder(noteID)
    if targetNote is missing value then error "This note is no longer in the Margin folder." number 1700
    tell application "/System/Applications/Notes.app"
        if password protected of targetNote or shared of targetNote or ((count attachments of targetNote) > 0) then error "Manage this note in Apple Notes." number 1700
        if not my sameText(body of targetNote, expectedBody) then error "This note changed in Apple Notes. Reopen it to see the latest version." number 1700
        delete targetNote
    end tell
    return true
end deletenote

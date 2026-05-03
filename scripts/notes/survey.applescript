-- Survey only: folder list, note count per folder, oldest/newest creation date.
-- No note bodies are read.
tell application "Notes"
    set output to ""
    set folderList to every folder
    repeat with f in folderList
        set folderName to name of f
        set notesInFolder to notes of f
        set noteCount to count of notesInFolder
        set oldestDate to ""
        set newestDate to ""
        if noteCount > 0 then
            set firstNote to item 1 of notesInFolder
            set oldestDate to creation date of firstNote
            set newestDate to creation date of firstNote
            repeat with n in notesInFolder
                set d to creation date of n
                if d < oldestDate then set oldestDate to d
                if d > newestDate then set newestDate to d
            end repeat
        end if
        set output to output & folderName & "	" & noteCount & "	" & (oldestDate as string) & "	" & (newestDate as string) & "
"
    end repeat
    return output
end tell

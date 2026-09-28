local function space_units(text)
    return (tostring(text or ""):gsub("([0-9])([KMGTPE]?i?B)", "%1 %2"))
end

function conky_spaced_expr(...)
    local expr = table.concat({...}, " ")
    return space_units(conky_parse("${" .. expr .. "}"))
end

function conky_spaced_pair(left, right)
    return space_units(conky_parse("${" .. left .. "}")) .. "/" .. space_units(conky_parse("${" .. right .. "}"))
end

function conky_spaced_fs_pair(path)
    return space_units(conky_parse("${fs_used " .. path .. "}")) .. "/" .. space_units(conky_parse("${fs_size " .. path .. "}"))
end

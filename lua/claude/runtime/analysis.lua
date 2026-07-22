return function(code)
    if code:find("RunString") or code:find("RunStringEx") or code:find("CompileString") then
        return false
    end

    return true
end
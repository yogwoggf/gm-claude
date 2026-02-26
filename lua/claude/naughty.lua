return function(ply)
    timer.Simple(math.random(4, 8), function()
        if not IsValid(ply) then return end
        net.Start("claude.chat")
        net.WriteString(string.format("%s is being a naughty gilber!!! Shame them!!!", ply:Nick()))
        net.Send(ply)

        ply:Say("I'm a naughty gilber!!! Shame me!!!")
        ply:Kill()
    end)
end
net.Receive("claude.chat", function()
  local msg = net.ReadString()
  chat.AddText(Color(125, 255, 115), "[LLM] ", Color(200, 200, 200), msg)
end)
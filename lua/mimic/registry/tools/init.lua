local modules = {
  require("mimic.registry.tools.python"),
  require("mimic.registry.tools.rust"),
  require("mimic.registry.tools.clang"),
  require("mimic.registry.tools.java"),
  require("mimic.registry.tools.typescript"),
}

local tools = {}
for _, module in ipairs(modules) do
  for _, tool in ipairs(module) do
    tools[#tools + 1] = tool
  end
end

return tools

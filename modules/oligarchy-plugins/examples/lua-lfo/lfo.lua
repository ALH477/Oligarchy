-- Control-rate LFO. Note what is not available in here: io, os, package,
-- require, load, debug. The host table is the entire outside world.

local M = {}

function M.init()
  host.log("info", "lfo online")
  return nil  -- non-nil string means "refuse to load"
end

function M.create(cfg)
  local p = {
    sr = cfg.sample_rate,
    phase = 0.0,
    rate = 1.0,
    depth = 1.0,
  }

  function p:process(input)
    local out = {}
    local inc = (2 * math.pi * self.rate) / self.sr
    for i = 1, #input do
      self.phase = self.phase + inc
      if self.phase > 2 * math.pi then self.phase = self.phase - 2 * math.pi end
      out[i] = input[i] * (1.0 - self.depth + self.depth * (0.5 + 0.5 * math.sin(self.phase)))
    end
    return out
  end

  function p:set_param(id, v)
    if id == 0 then self.rate = v elseif id == 1 then self.depth = v end
  end

  function p:get_param(id)
    if id == 0 then return self.rate elseif id == 1 then return self.depth end
    return 0.0
  end

  function p:reset() self.phase = 0.0 end

  return p
end

function M.params()
  return {
    { id = 0, name = "rate",  min = 0.01, max = 20.0, default = 1.0 },
    { id = 1, name = "depth", min = 0.0,  max = 1.0,  default = 1.0 },
  }
end

return M

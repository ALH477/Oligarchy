-- SPDX-License-Identifier: LGPL-3.0-only
-- DCF-Talk as an Oligarchy plugin: a control surface and nothing else.
--
-- Note what is absent. There is no `create` and no `params`, so the host's
-- exports_dsp() answers false and create_processor() returns Ok(None). That is
-- not a stub or a TODO — it is what the overwhelming majority of plugins look
-- like. Compare examples/lua-lfo/lfo.lua, which does provide `create` and is
-- therefore the unusual shape.
--
-- ── A LIMITATION THIS EXAMPLE EXISTS TO EXPOSE ─────────────────────────────
--
-- The certified DCF stack is SIX Lua modules (dcf_text, dcf_voice,
-- dcf_transport, dcf_snake, dcf_history, dcf_audio). This file cannot load any
-- of them, and neither can any other Lua-tier plugin: strip_dangerous_globals
-- in tiers/lua.rs sets `dofile`, `require`, `loadfile`, `load`, `loadstring`,
-- `package`, `io` and `os` to nil. The reasoning is sound — `load` would let a
-- plugin build chunks at runtime and walk around source review — but the
-- consequence is that the Lua tier can only run SINGLE-FILE plugins, which
-- excludes essentially every real Lua library including this one.
--
-- So what follows is the control surface, complete and self-contained, with a
-- minimal inline frame encoder standing in for dcf_text. It is honest about
-- being a shape rather than a wiring. The fix is a host-mediated module loader
-- that resolves a fixed allowlist out of the artifact's own $STORE — reads
-- Landlock already permits — rather than restoring `dofile`. Recorded in
-- docs/plugins-roadmap.md.
--
-- `host` is the entire outside world: log, now_ns, read_config,
-- has_capability. Nothing else is reachable, by design.

local M = {}

local state = {
  nick    = "anon",
  channel = nil,
  log     = {},
  seq     = 0,
}

function M.init()
  state.nick = host.read_config("nick") or "anon"
  -- Declared in the manifest's host_services, so this is a real question with
  -- a real answer rather than an assumption.
  if not host.has_capability("read_config") then
    return "dcf-talk needs the read_config host service"
  end
  host.log("info", "dcf-talk ready as " .. state.nick)
end

-- A DeModFrame is a fixed 17-byte header and no variable-length parsing, which
-- is why the frame format has no parser to exploit. Sketched here rather than
-- imported; the certified encoder lives in modules/demod-talk.
local function encode(channel, nick, body)
  state.seq = (state.seq + 1) % 65536
  return string.format("DATA0|%05d|%s|%s|%s", state.seq, channel, nick, body)
end

-- The whole plugin surface: verbs in, one string out. This is the `control`
-- interface from the WIT, and for a plugin like this it is the entire API.
function M.handle_command(verb, args)
  if verb == "nick" then
    state.nick = args[1] or state.nick
    return "nick = " .. state.nick

  elseif verb == "join" then
    state.channel = args[1] or "#general"
    return "joined " .. state.channel

  elseif verb == "say" then
    if not state.channel then return "error: join a channel first" end
    local body = table.concat(args, " ")
    local frame = encode(state.channel, state.nick, body)
    state.log[#state.log + 1] = state.nick .. ": " .. body
    -- Where transport.send(frame) goes. The socket is the plugin unit's, granted
    -- by caps.network — see the manifest for why that grant is coarser than it
    -- looks for a UDP protocol.
    host.log("debug", "tx " .. #frame .. "B on " .. state.channel)
    return "sent"

  elseif verb == "history" then
    local n = tonumber(args[1]) or 20
    local out, first = {}, math.max(1, #state.log - n + 1)
    for i = first, #state.log do out[#out + 1] = state.log[i] end
    return table.concat(out, "\n")

  else
    return "error: unknown verb " .. tostring(verb)
      .. " (nick|join|say|history)"
  end
end

-- Session save/restore. Deliberately just the session: message history belongs
-- in StreamDB under $STATE, not in an opaque blob the host round-trips.
function M.save_state()
  return string.format("%s\n%s", state.nick, state.channel or "")
end

function M.load_state(blob)
  local nick, channel = blob:match("([^\n]*)\n([^\n]*)")
  if nick and nick ~= "" then state.nick = nick end
  if channel and channel ~= "" then state.channel = channel end
end

return M

-- Local HTTP fixture using Neovim's libuv: no Python or live Jira required.
local uv = vim.uv or vim.loop
local M = {}

---Run fn against a local server. Returning false from reply leaves it waiting.
function M.with_server(reply, fn)
  local listener = uv.new_tcp()
  assert(listener:bind("127.0.0.1", 0))
  local clients = {}
  local server = { requests = {} }
  server.url = "http://127.0.0.1:" .. listener:getsockname().port

  assert(listener:listen(16, function(err)
    if err then
      server.error = err
      return
    end
    local client = uv.new_tcp()
    clients[#clients + 1] = client
    listener:accept(client)
    local received = ""
    client:read_start(function(read_err, chunk)
      if read_err then
        server.error = read_err
      end
      if not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      received = received .. chunk
      local boundary = received:find("\r\n\r\n", 1, true)
      if not boundary then
        return
      end
      local head = received:sub(1, boundary - 1)
      local method, path = head:match("^(%S+) (%S+) HTTP/")
      local headers = {}
      for name, value in head:gmatch("\r\n([^:]+):%s*([^\r\n]*)") do
        headers[name:lower()] = value
      end
      local length = tonumber(headers["content-length"]) or 0
      local body = received:sub(boundary + 4)
      if #body < length then
        return
      end
      client:read_stop()
      local request = { method = method, path = path, headers = headers, body = body:sub(1, length) }
      server.requests[#server.requests + 1] = request
      local response = reply
      if type(reply) == "function" then
        response = reply(request)
      end
      if response == false then
        return
      end
      response = response or { status = 204 }
      local text = response.body or ""
      local extra_headers = ""
      for name, value in pairs(response.headers or {}) do
        extra_headers = extra_headers .. name .. ": " .. value .. "\r\n"
      end
      local output = "HTTP/1.1 "
        .. response.status
        .. " Test\r\nContent-Type: application/json\r\n"
        .. extra_headers
        .. "Content-Length: "
        .. #text
        .. "\r\nConnection: close\r\n\r\n"
        .. text
      client:write(output, function()
        if not client:is_closing() then
          client:close()
        end
      end)
    end)
  end))

  local ok, err = pcall(fn, server)
  for _, client in ipairs(clients) do
    if not client:is_closing() then
      client:close()
    end
  end
  listener:close()
  if not ok then
    error(err, 0)
  end
  if server.error then
    error(server.error, 0)
  end
end

return M

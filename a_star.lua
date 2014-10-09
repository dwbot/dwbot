a_star = {}

do
  -- standard heap implementation --------
  local function push (tbl, v)
    table.insert(tbl, v)
    local n = #tbl
    local i = math.floor(n / 2)
    local val = v.val
    -- push the value up the heap
    while i >= 1 do
      if tbl[i].val <= val then break end
      tbl[i], tbl[n] = tbl[n], tbl[i]
      n, i = i, math.floor(i / 2)
    end
  end
  
  local function pop (tbl)
    if #tbl <= 2 then
      return table.remove(tbl, 1)
    elseif #tbl > 2 then
      local result = tbl[1]
      tbl[1] = table.remove(tbl)
      local val = tbl[1].val
      -- push the value down the heap
      local n, i, j = #tbl, 1, 2
      while j <= n do
        local v2 = tbl[j].val
        if j < n then
          local v3 = tbl[j+1].val
          if v3 < v2 then
            v2 = v3
            j = j + 1
          end
        end
        if val <= v2 then break end
        tbl[i], tbl[j] = tbl[j], tbl[i]
        i, j = j, j*2
      end
      return result
    end
  end

  local dxs, dys = {1,0,-1,0}, {0,1,0,-1}
  local dirs = {"e", "s", "w", "n"}
  
  -- a* ----------------------------------
  
  function a_star.a_star (x1, y1, x2, y2, cost_fn, max_dist)
    local function dist_fn (x, y)
      local dx, dy = x2-x, y2-y
      return (dx*dx+dy*dy)^0.5
    end

    local visited = {}
    local queue = {}
    visited[x1 .. "," .. y1] = true
    push(queue, { val = dist_fn(x1, y1), cost = 0, x = x1, y = y1 })
    while #queue > 0 do
      local v = pop(queue)
      if v.x == x2 and v.y == y2 then break end
      if max_dist and v.val > max_dist then return end                  -- no path under the max distance
      for i=1,4 do
        local dx, dy = dxs[i], dys[i]
        local xn, yn = v.x+dx, v.y+dy
        local k = xn .. "," .. yn
        if not visited[k] then
          visited[k] = i
          local cost = cost_fn(xn, yn)
          if cost > 0 then
            local new_cost = v.cost + cost
            push(queue, { val = dist_fn(xn, yn) + new_cost,
                          cost = new_cost,
                          x = xn, y = yn })
          end
        end
      end
    end
  
    -- work backwards to the start
    local result = {}
    local xn, yn = x2, y2
    while xn ~= x1 or yn ~= y1 do
      local k = xn .. "," .. yn
      local i = visited[k]
      if not i then return end          -- no path
      -- push to the front of the path
      table.insert(result, 1, { dir=dirs[i], x=xn, y=yn })
      xn = xn - dxs[i]
      yn = yn - dys[i]
    end
    return result
  end
end

return a_star
